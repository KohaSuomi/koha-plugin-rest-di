#!/usr/bin/perl

use Modern::Perl;
use FindBin;
use lib "$FindBin::Bin/../../../../../../";

use Test::More;

BEGIN {
    use_ok('Koha::Plugin::Fi::KohaSuomi::DI::Koha::Availability::Checks::Item');
}

done_testing();
