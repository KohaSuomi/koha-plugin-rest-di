#!/usr/bin/perl

use Modern::Perl;
use FindBin;
use lib "$FindBin::Bin/../../../../../../";

use Test::More;

use C4::Context;
use Koha::Database;
use Koha::DateUtils qw( dt_from_string );
use Koha::Items;
use Koha::Patrons;
use t::lib::Mocks;

use Koha::Plugin::Fi::KohaSuomi::DI::Koha::Availability::Checks::Item;

my $schema = Koha::Database->new->schema;
$schema->storage->txn_begin;

my $item = Koha::Items->search(
    { notforloan => 0, onloan => undef, damaged => 0, itemlost => 0, withdrawn => 0 },
    { rows => 1 }
)->next;
die "No suitable (available) items found in database\n" unless $item;

my @patrons = Koha::Patrons->search( {}, { rows => 5 } )->as_list;
die "Not enough patrons found in database\n" unless @patrons >= 2;

sub new_patron {
    return $patrons[ rand @patrons ];
}

sub clear_holds {
    my ($it) = @_;
    $schema->resultset('Reserve')->search( { itemnumber => $it->itemnumber } )->delete;
    $schema->resultset('Reserve')->search( { biblionumber => $it->biblionumber } )->delete;
}

subtest 'no holds -> not held' => sub {
    plan tests => 1;

    clear_holds($item);
    my $checks = Koha::Plugin::Fi::KohaSuomi::DI::Koha::Availability::Checks::Item->new($item);
    is( $checks->held, undef, 'item without holds is not held' );
};

subtest 'found W hold -> Waiting' => sub {
    plan tests => 3;

    clear_holds($item);
    my $patron = new_patron();
    $schema->resultset('Reserve')->create(
        {
            borrowernumber => $patron->borrowernumber,
            biblionumber   => $item->biblionumber,
            itemnumber     => $item->itemnumber,
            branchcode     => $item->homebranch,
            priority       => 1,
            found          => 'W',
            suspend        => 0,
            reservedate    => dt_from_string()->ymd,
        }
    );

    my $checks = Koha::Plugin::Fi::KohaSuomi::DI::Koha::Availability::Checks::Item->new($item);
    my $held   = $checks->held;
    ok( defined $held, 'held is defined' );
    is( $held->status, 'Waiting', 'status is Waiting' );
    is( $held->borrowernumber, $patron->borrowernumber, 'borrowernumber matches' )
        if defined $held;
};

subtest 'found P hold -> Processing' => sub {
    plan tests => 2;

    clear_holds($item);
    my $patron = new_patron();
    $schema->resultset('Reserve')->create(
        {
            borrowernumber => $patron->borrowernumber,
            biblionumber   => $item->biblionumber,
            itemnumber     => $item->itemnumber,
            branchcode     => $item->homebranch,
            priority       => 1,
            found          => 'P',
            suspend        => 0,
            reservedate    => dt_from_string()->ymd,
        }
    );

    my $checks = Koha::Plugin::Fi::KohaSuomi::DI::Koha::Availability::Checks::Item->new($item);
    my $held   = $checks->held;
    ok( defined $held, 'held is defined' );
    is( $held->status, 'Processing', 'status is Processing' );
};

subtest 'item-level hold -> Reserved when checkout on hold disallowed' => sub {
    plan tests => 2;

    clear_holds($item);
    my $patron = new_patron();

    t::lib::Mocks::mock_preference( 'AllowItemsOnHoldCheckoutSIP', 0 );
    t::lib::Mocks::mock_preference( 'AllowItemsOnHoldCheckoutSCO', 0 );

    $schema->resultset('Reserve')->create(
        {
            borrowernumber => $patron->borrowernumber,
            biblionumber   => $item->biblionumber,
            itemnumber     => $item->itemnumber,
            branchcode     => $item->homebranch,
            priority       => 1,
            found          => undef,
            suspend        => 0,
            reservedate    => dt_from_string()->ymd,
        }
    );

    my $checks = Koha::Plugin::Fi::KohaSuomi::DI::Koha::Availability::Checks::Item->new($item);
    my $held   = $checks->held;
    ok( defined $held, 'held is defined' );
    is( $held->status, 'Reserved', 'status is Reserved' );
};

subtest 'on-order (notforloan) item with holds -> not held' => sub {
    plan tests => 1;

    clear_holds($item);
    my $patron = new_patron();

    # Mark item as on-order / not for loan.
    $item->notforloan(1)->store;

    $schema->resultset('Reserve')->create(
        {
            borrowernumber => $patron->borrowernumber,
            biblionumber   => $item->biblionumber,
            itemnumber     => $item->itemnumber,
            branchcode     => $item->homebranch,
            priority       => 1,
            found          => undef,
            suspend        => 0,
            reservedate    => dt_from_string()->ymd,
        }
    );

    t::lib::Mocks::mock_preference( 'TrapHoldsOnOrder', 1 );

    my $checks = Koha::Plugin::Fi::KohaSuomi::DI::Koha::Availability::Checks::Item->new($item);
    is( $checks->held, undef, 'on-order item with holds is not reported as held' );

    $item->notforloan(0)->store;
};

subtest 'found T hold -> Transferred only when checkout on hold disallowed' => sub {
    plan tests => 2;

    clear_holds($item);
    my $patron = new_patron();

    t::lib::Mocks::mock_preference( 'AllowItemsOnHoldCheckoutSIP', 0 );
    t::lib::Mocks::mock_preference( 'AllowItemsOnHoldCheckoutSCO', 0 );

    $schema->resultset('Reserve')->create(
        {
            borrowernumber => $patron->borrowernumber,
            biblionumber   => $item->biblionumber,
            itemnumber     => $item->itemnumber,
            branchcode     => $item->homebranch,
            priority       => 1,
            found          => 'T',
            suspend        => 0,
            reservedate    => dt_from_string()->ymd,
        }
    );

    my $checks = Koha::Plugin::Fi::KohaSuomi::DI::Koha::Availability::Checks::Item->new($item);
    my $held   = $checks->held;
    ok( defined $held, 'held is defined' );
    is( $held->status, 'Transferred', 'status is Transferred' );
};

subtest 'mixed found holds on one item' => sub {
    plan tests => 1;

    clear_holds($item);
    my $p1 = new_patron();
    my $p2 = new_patron();

    $schema->resultset('Reserve')->create(
        {
            borrowernumber => $p1->borrowernumber,
            biblionumber   => $item->biblionumber,
            itemnumber     => $item->itemnumber,
            branchcode     => $item->homebranch,
            priority       => 1,
            found          => 'W',
            suspend        => 0,
            reservedate    => dt_from_string()->ymd,
        }
    );
    $schema->resultset('Reserve')->create(
        {
            borrowernumber => $p2->borrowernumber,
            biblionumber   => $item->biblionumber,
            itemnumber     => $item->itemnumber,
            branchcode     => $item->homebranch,
            priority       => 2,
            found          => undef,
            suspend        => 0,
            reservedate    => dt_from_string()->ymd,
        }
    );

    my $checks = Koha::Plugin::Fi::KohaSuomi::DI::Koha::Availability::Checks::Item->new($item);
    my $held   = $checks->held;
    ok( defined $held, 'item with mixed found/unfound holds is held' );
};

$schema->storage->txn_rollback;
done_testing();
