use strict;
use warnings;

use APNIC::RPKI::RTR::Server;
use APNIC::RPKI::RTR::Server::Maintainer;
use APNIC::RPKI::RTR::Client;
use APNIC::RPKI::RTR::PDU::IPv4Prefix;
use APNIC::RPKI::RTR::Changeset;

use File::Temp qw(tempdir);
use File::Slurp qw(read_file);

use Data::Dumper;

use Test::More tests => 14;

sub create_server {
    my ($pdus) = @_;

    my $data_dir = tempdir(CLEANUP => 1);
    my $mnt =
        APNIC::RPKI::RTR::Server::Maintainer->new(
            data_dir => $data_dir
        );
    my $changeset = APNIC::RPKI::RTR::Changeset->new();

    $changeset->add_pdu($_) foreach @$pdus;

    # my $ipv4_pdu =
    # APNIC::RPKI::RTR::PDU::IPv4Prefix->new(
    #     version       => 1,
    #     flags         => 1,
    #     asn           => 4608,
    #     address       => '1.0.0.0',
    #     prefix_length => 24,
    #     max_length    => 32
    # );
    # $changeset->add_pdu($ipv4_pdu);
    $mnt->apply_changeset($changeset);

    my $port =
    ($$ + int(rand(1024))) % (65535 - 1024) + 1024;
    print "Creating server (data directory: $data_dir, port: $port)\n";
    my $server =
        APNIC::RPKI::RTR::Server->new(
            server   => '127.0.0.1',
            port     => $port,
            data_dir => $data_dir,
        );

    return $server;
}

# Run two servers with some simple vrps state.
my @servers = (
    create_server(
        [
            APNIC::RPKI::RTR::PDU::IPv4Prefix->new(
                version       => 1,
                flags         => 1,
                asn           => 4608,
                address       => '1.0.0.0',
                prefix_length => 24,
                max_length    => 32
            ),
        ]
    ),
    create_server(
        [
            APNIC::RPKI::RTR::PDU::IPv4Prefix->new(
                version       => 1,
                flags         => 1,
                asn           => 2000,
                address       => '10.0.0.0',
                prefix_length => 24,
                max_length    => 32
            ),
        ]
    ),
);
my @server_pids = ();
foreach my $server (@servers) {
    if (my $server_pid = fork()) {
        push @server_pids, $server_pid;
    } else {
        $server->run(());
        exit(0);
    }
}

# Initialise the client to fetch from both servers.
my $client_data_dir = tempdir(CLEANUP => 1);
my $server_arguments =
    join " ",
    map {
        sprintf("--server %s --port %d --version 2", $_->{'server'}, $_->{port})
    } @servers;
my $run_client =
    "perl -Mblib -MCarp::Always bin/rpki-rtr-client $client_data_dir";
system("$run_client init $server_arguments");
system("$run_client reset --client_id 0");
system("$run_client reset --client_id 1");

# Verified fetched state in cache matches server's.
my $client0 = APNIC::RPKI::RTR::Client->deserialise_json(
    read_file("$client_data_dir/client0.json")
);
my $client0_state = $client0->state();
is_deeply(
    $client0_state->{vrps},
    {
        "4608" => {
            "1.0.0.0" => {
                "24" => {
                    "32" => 1
                }
            }
        }
    },
    "Correct vrp fetched from cache/server 0."
);

my $client1 = APNIC::RPKI::RTR::Client->deserialise_json(
    read_file("$client_data_dir/client1.json")
);
my $client1_state = $client1->state();
is_deeply(
    $client1_state->{vrps},
    {
        "2000" => {
            "10.0.0.0" => {
                "24" => {
                    "32" => 1
                }
            }
        }
    },
    "Correct vrp fetched from cache/server 1."
);

foreach my $pid (@server_pids) {
    kill('TERM', $pid);
}