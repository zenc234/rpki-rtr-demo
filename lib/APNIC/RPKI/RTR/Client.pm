package APNIC::RPKI::RTR::Client;

use warnings;
use strict;

use File::Slurp qw(write_file);
use IO::Socket qw(AF_INET SOCK_STREAM TCP_NODELAY IPPROTO_TCP);
use JSON::XS qw(encode_json decode_json);
use List::Util qw(max);
use Math::BigInt;
use Net::IP::XS qw(ip_inttobin ip_bintoip ip_compress_address);

use APNIC::RPKI::RTR::Changeset;
use APNIC::RPKI::RTR::State;
use APNIC::RPKI::RTR::PDU::Utils qw(parse_pdu);
use APNIC::RPKI::RTR::PDU::ResetQuery;
use APNIC::RPKI::RTR::Utils qw(inet_ntop dprint);

our $VERSION = "0.1";

sub new
{
    my $class = shift;
    my %args = @_;

    my $server = $args{'server'};
    if (not $server) {
        die "A server must be provided.";
    }
    my @svs = @{$args{'supported_versions'} || [1, 2]};
    for my $sv (@svs) {
        if (not (($sv >= 0) and ($sv <= 2))) {
            die "Version '$sv' is not supported.";
        }
    }

    my $port = $args{'port'} || 323;

    my $self = {
        supported_versions    => \@svs,
        sv_lookup             => { map { $_ => 1 } @svs },
        max_supported_version => (max @svs),
        server                => $server,
        port                  => $port,
        debug                 => $args{'debug'},
        strict_send           => $args{'strict_send'},
        strict_receive        => $args{'strict_receive'},
    };
    bless $self, $class;
    return $self;
}

sub _init_socket
{
    my ($self) = @_;

    dprint("client: initialising socket");
    $self->_close_socket();

    my ($server, $port) = @{$self}{qw(server port)};
    my $socket = IO::Socket->new(
        Domain   => AF_INET,
        Type     => SOCK_STREAM,
        proto    => 'tcp',
        PeerHost => $server,
        PeerPort => $port,
    );
    $socket->setsockopt(IPPROTO_TCP, TCP_NODELAY, 1);

    if (not $socket) {
        die "Unable to connect to '$server:$port': $!";
    }

    $self->{'socket'} = $socket;

    return 1;
}

sub _init_socket_if_not_exists
{
    my ($self) = @_;

    if (not $self->{'socket'}) {
        $self->_init_socket();
    }

    return 1;
}

sub _close_socket
{
    my ($self) = @_;

    my $socket = $self->{'socket'};
    if ($socket) {
        dprint("client: closing existing socket");
        $socket->close();
    } else {
        dprint("client: no existing socket to close");
    }
    delete $self->{'socket'};

    return 1;
}

sub _send_reset_query
{
    my ($self, $version) = @_;

    dprint("client: sending reset query");
    my $socket = $self->{'socket'};
    my $reset_query =
        APNIC::RPKI::RTR::PDU::ResetQuery->new(
            version =>
                ((defined $version)
                    ? $version
                    : $self->{'max_supported_version'})
        );
    my $data = $reset_query->serialise_binary();
    my $res = $socket->send($data);
    if ($res != length($data)) {
        die "Got unexpected send result for reset query: '$res' ($!)";
    }
    dprint("client: sent reset query");

    return $res;
}

sub _send_serial_query
{
    my ($self) = @_;

    dprint("client: sending serial query");
    my $socket = $self->{'socket'};
    my $state = $self->{'state'};
    dprint("client: session ID is '".$state->session_id()."'");
    dprint("client: serial number is '".$state->{'serial_number'}."'");
    my $serial_query =
        APNIC::RPKI::RTR::PDU::SerialQuery->new(
            version       => $self->{'current_version'},
            session_id    => $state->session_id(),
            serial_number => $state->{'serial_number'},
        );
    my $data = $serial_query->serialise_binary();
    my $res = $socket->send($data);
    if ($res != length($data)) {
        die "Got unexpected send result for serial query: '$res' ($!)";
    }
    dprint("client: sent serial query");

    return $res;
}

sub _receive_cache_response
{
    my ($self) = @_;

    dprint("client: receiving cache response");
    my $socket = $self->{'socket'};
    my $pdu = parse_pdu($socket);

    my $type = $pdu->type();
    dprint("client: received PDU: ".$pdu->serialise_json());
    if ($type == 3) {
        dprint("client: received cache response PDU");
        my $state = $self->{'state'};
        if ($state and ($pdu->session_id() != $state->{'session_id'})) {
            my $err_pdu =
                APNIC::RPKI::RTR::PDU::ErrorReport->new(
                    version    => $self->{'current_version'},
                    error_code => 0,
                );
            $socket->send($err_pdu->serialise_binary());
            die "client: got PDU with unexpected session";
        }
        delete $self->{'last_failure'};
        return $pdu;
    } elsif ($type == 10) {
        dprint("client: received error response PDU");
        $self->{'last_failure'} = time();
        $self->_close_socket();
        if ($pdu->error_code() == 2) {  
            die "Server has no data";
        } elsif ($pdu->error_code() == 4) {
            my $max_version = $pdu->version();
            die "Server does not support client version ".
                "(maximum supported version is '$max_version')";
        } else {
            die "Got error response: ".$pdu->serialise_json();
        }
    } else {
        dprint("client: received unexpected PDU");
        $self->{'last_failure'} = time();
        die "Got unexpected PDU: ".$pdu->serialise_json();
    }
}

sub _process_responses
{
    my ($self) = @_;

    dprint("client: processing responses");

    my $socket  = $self->{'socket'};
    my $changeset = APNIC::RPKI::RTR::Changeset->new();
    my $serial_notify = 0;

    for (;;) {
        dprint("client: processing response");
        my $pdu = parse_pdu($socket);
        dprint("client: processing response: got PDU: ".$pdu->serialise_json());
        if ($pdu->version() != $self->{'current_version'}) {
            if ($pdu->type() == 10) {
                die "client: got error PDU with unexpected version";
            }
	    my $err_pdu =
		APNIC::RPKI::RTR::PDU::ErrorReport->new(
		    version    => $self->{'current_version'},
		    error_code => 8,
		);
	    $socket->send($err_pdu->serialise_binary());
            die "client: got PDU with unexpected version";
        }
        if ($changeset->can_add_pdu($pdu)) {
            $changeset->add_pdu($pdu);
        } elsif ($pdu->type() == 7) {
            return (1, $changeset, $pdu);
        } elsif ($pdu->type() == 10) {
            return (0, $changeset, $pdu);
        } elsif ($pdu->type() == 0) {
            $serial_notify = 1;
        } elsif ($pdu->type() == 8) {
            dprint("client: got cache reset PDU");
            return (0, $changeset, $pdu);
        } else {
            warn "Unexpected PDU";
        }
    }

    return 0;
}

sub reset
{
    my ($self, $force) = @_; 

    if (not $force) {
        my $last_failure = $self->{'last_failure'};
        if ($last_failure) {
            my $eod = $self->{'eod'};
            if ($eod and ($self->{'current_version'} > 0)) {
                my $retry_interval = $eod->refresh_interval();
                my $min_retry_time = $last_failure + $retry_interval;
                if (time() < $min_retry_time) {
                    dprint("client: not retrying, retry interval not reached");
                    return;
                }
            }
        }
    }

    $self->_init_socket_if_not_exists();
    $self->_send_reset_query();
    my $pdu = eval { $self->_receive_cache_response(); };
    if (my $error = $@) {
        delete $self->{'socket'};
        if ($error =~ /maximum supported version is '(\d+)'/) {
            my $version = $1;
            if ($self->{'sv_lookup'}->{$version}) {
                $self->_init_socket_if_not_exists();
                $self->_send_reset_query($version);
                # No point trying to catch the error here.
                $pdu = $self->_receive_cache_response();
            } else {
                die "Unsupported server version '$version'";
            }
        } else {
            die $error;
        }
    }
    my $version = $pdu->version();
    $self->{'current_version'} = $version;

    my $state =
        APNIC::RPKI::RTR::State->new(
            session_id => $pdu->session_id(),
        );
    $self->{'state'} = $state;

    my ($res, $changeset, $other_pdu) = $self->_process_responses();
    if (not $res) {
        if ($other_pdu) {
            warn $other_pdu->serialise_json(),"\n";
        }
        die "Failed to process cache responses";
    } else {
        $state->apply_changeset($changeset);
        $self->{'eod'} = $other_pdu;
        $self->{'last_run'} = time();
        $state->{'serial_number'} = $other_pdu->serial_number();
    }

    $self->_close_socket();

    return 1;
}

sub refresh
{
    my ($self, $force) = @_;

    if (not $force) {
        my $last_failure = $self->{'last_failure'};
        my $eod = $self->{'eod'};
        if ($last_failure and $eod and ($self->{'current_version'} > 0)) {
            my $retry_interval = $eod->refresh_interval();
            my $min_retry_time = $last_failure + $retry_interval;
            if (time() < $min_retry_time) {
                dprint("client: not retrying, retry interval not reached");
                return;
            }
        }
        if ($eod and ($self->{'current_version'} > 0)) {
            my $last_run = $self->{'last_run'};
            my $refresh_interval = $eod->refresh_interval();
            my $min_refresh_time = $last_run + $refresh_interval;
            if (time() < $min_refresh_time) {
                dprint("client: not refreshing, refresh interval not reached");
                return;
            }
        }
    }

    $self->_init_socket_if_not_exists();
    $self->_send_serial_query();
    my $pdu = $self->_receive_cache_response();
    my $version = $pdu->version();
    $self->{'current_version'} = $version;
    # todo: negotiation checks needed here.

    my ($res, $changeset, $other_pdu) = $self->_process_responses();
    if (not $res) {
        if ($other_pdu) {
            if ($other_pdu->type() == 8) {
                # Cache reset PDU: call reset.
                $self->{'state'}    = undef;
                $self->{'eod'}      = undef;
                $self->{'last_run'} = undef;
                $self->{'socket'}   = undef;
                return $self->reset(1);
            }
            warn $other_pdu->serialise_json(),"\n";
        }
        die "Failed to process cache responses";
    } else {
        $self->{'state'}->apply_changeset($changeset);
        $self->{'eod'} = $other_pdu;
        $self->{'last_run'} = time();
        $self->{'state'}->{'serial_number'} = $other_pdu->serial_number();
    }

    $self->_close_socket();

    return 1;
}

sub reset_if_required
{
    my ($self) = @_;

    my $eod          = $self->{'eod'};
    my $last_failure = $self->{'last_failure'};
    my $last_run     = $self->{'last_run'};

    if ($last_failure > $last_run) {
        my $last_use_time;
        if ($eod and ($self->{'current_version'} > 0)) {
            $last_use_time =
                $last_failure + $eod->expire_interval();
        } else {
            # It may be worth making this configurable, though it is
            # only useful for v0 clients.
            $last_use_time = $last_failure + 3600;
        }
        if (time() > $last_use_time) {
            dprint("client: removing state and resetting, reached expiry time");
            delete $self->{'state'};
            delete $self->{'eod'};
            delete $self->{'last_run'};
            delete $self->{'last_failure'};
            return $self->reset();
        }
    }

    return;
}

sub state
{
    my ($self) = @_;

    return $self->{'state'};
}

sub serialise_json
{
    my ($self) = @_;

    my $data = {
        ($self->{'state'}
            ? (state => $self->{'state'}->serialise_json())
            : ()),
        ($self->{'eod'}
            ? (eod => $self->{'eod'}->serialise_json())
            : ()),
        (map {
            $self->{$_} ? ($_ => $self->{$_}->serialise_json()) : ()
        } qw(state eod)),
        (map {
            $self->{$_} ? ($_ => $self->{$_}) : ()
        } qw(server port last_run last_failure supported_versions
             sv_lookup max_supported_version)),
    };
    return encode_json($data);
}

sub deserialise_json
{
    my ($class, $data) = @_;

    my $obj = decode_json($data);
    if ($obj->{'state'}) {
        $obj->{'state'} =
            APNIC::RPKI::RTR::State->deserialise_json($obj->{'state'});
    }
    if ($obj->{'eod'}) {
        $obj->{'eod'} =
            APNIC::RPKI::RTR::PDU::EndOfData->deserialise_json($obj->{'eod'});
    }
    bless $obj, $class;
    return $obj;
}

1;
