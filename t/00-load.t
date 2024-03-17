#!/usr/bin/perl

use warnings;
use strict;

use Test::More tests => 22;

BEGIN {
    use_ok("APNIC::RPKI::RTR::Client");
    use_ok("APNIC::RPKI::RTR::Server");
    use_ok("APNIC::RPKI::RTR::Server::Maintainer");
    use_ok("APNIC::RPKI::RTR::Session");
    use_ok("APNIC::RPKI::RTR::Utils");
    use_ok("APNIC::RPKI::RTR::State");
    use_ok("APNIC::RPKI::RTR::PDU::SerialNotify");
    use_ok("APNIC::RPKI::RTR::PDU::EndOfData");
    use_ok("APNIC::RPKI::RTR::PDU::CacheResponse");
    use_ok("APNIC::RPKI::RTR::PDU::ASPA");
    use_ok("APNIC::RPKI::RTR::PDU::ErrorReport");
    use_ok("APNIC::RPKI::RTR::PDU::Utils");
    use_ok("APNIC::RPKI::RTR::PDU::CacheReset");
    use_ok("APNIC::RPKI::RTR::PDU::IPv4Prefix");
    use_ok("APNIC::RPKI::RTR::PDU::IPv6Prefix");
    use_ok("APNIC::RPKI::RTR::PDU::SerialQuery");
    use_ok("APNIC::RPKI::RTR::PDU::RouterKey");
    use_ok("APNIC::RPKI::RTR::PDU::ResetQuery");
    use_ok("APNIC::RPKI::RTR::Changeset");
    use_ok("APNIC::RPKI::RTR::PDU");
    use_ok("APNIC::RPKI::Validator::ROA");
    use_ok("APNIC::RPKI::Validator::ASPA");
}

1;
