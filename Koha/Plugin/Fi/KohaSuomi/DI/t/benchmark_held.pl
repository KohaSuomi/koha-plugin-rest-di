#!/usr/bin/perl
use Modern::Perl;
use Koha::Database;
use C4::Context;
use Koha::DateUtils qw( dt_from_string );
use Time::HiRes qw(time);

use C4::Reserves;
use Koha::Items;
use Koha::Plugin::Fi::KohaSuomi::DI::Koha::Availability::Checks::Item;

my $schema = Koha::Database->new->schema;
$schema->storage->txn_begin;

my $dbh = C4::Context->dbh;

my ( $itemnumber, $biblionumber, $homebranch ) = $dbh->selectrow_array(
    q{SELECT itemnumber, biblionumber, homebranch FROM items LIMIT 1}
);
die "No items found in database\n" unless $itemnumber;

my $patrons = $dbh->selectall_arrayref(
    q{SELECT borrowernumber, branchcode FROM borrowers LIMIT 10},
    { Slice => {} }
);
die "No borrowers found in database\n" unless @$patrons;

my $item = Koha::Items->find($itemnumber);

# Mark a second item as not-for-loan by updating a copy row? Use same item? 
# Instead create not-for-loan status by setting notforloan on a cloned item row.
my ( $nf_itemnumber, $nf_biblionumber, $nf_homebranch ) = $dbh->selectrow_array(
    q{SELECT itemnumber, biblionumber, homebranch FROM items LIMIT 1 OFFSET 1}
);
my $nf_item = $nf_itemnumber ? Koha::Items->find($nf_itemnumber) : $item;
if ($nf_item && $nf_item->itemnumber != $item->itemnumber) {
    $nf_item->notforloan(1)->store;
}

my @found_statuses = ( undef, 'W', 'P', 'T', undef );
for ( my $i = 1; $i <= 500; $i++ ) {
    my $p = $patrons->[ $i % scalar(@$patrons) ];
    my $found = $found_statuses[ $i % scalar(@found_statuses) ];
    $dbh->do(
        q|INSERT INTO reserves (borrowernumber, biblionumber, itemnumber, branchcode, priority, reservedate, found, suspend) VALUES (?,?,?,?,NOW(),?,?,0)|,
        undef,
        $p->{borrowernumber},
        $biblionumber,
        $itemnumber,
        $homebranch,
        $i,
        $found
    );

    if ( $i <= 50 && $nf_item && $nf_item->itemnumber != $item->itemnumber ) {
        my $p2 = $patrons->[ ( $i + 1 ) % scalar(@$patrons) ];
        $dbh->do(
            q|INSERT INTO reserves (borrowernumber, biblionumber, itemnumber, branchcode, priority, reservedate, found, suspend) VALUES (?,?,?,?,?,NOW(),NULL,0)|,
            undef,
            $p2->{borrowernumber},
            $nf_item->biblionumber,
            $nf_item->itemnumber,
            $nf_item->homebranch,
            $i
        );
    }
}

C4::Context->set_preference( 'AllowItemsOnHoldCheckoutSIP', 0 );
C4::Context->set_preference( 'AllowItemsOnHoldCheckoutSCO', 0 );

my $checks    = Koha::Plugin::Fi::KohaSuomi::DI::Koha::Availability::Checks::Item->new($item);
my $nf_checks = $nf_item && $nf_item->itemnumber != $item->itemnumber
    ? Koha::Plugin::Fi::KohaSuomi::DI::Koha::Availability::Checks::Item->new($nf_item)
    : undef;

my $iterations = 2;

my $t0 = time();
for ( 1 .. $iterations ) {
    my ( $status, $reserve, $all ) = C4::Reserves::CheckReserves($item);
}
my $t1 = time();
my $old_ms = ( ( $t1 - $t0 ) / $iterations ) * 1000;

my $t2 = time();
for ( 1 .. $iterations ) {
    my $held = $checks->held;
}
my $t3 = time();
my $new_ms = ( ( $t3 - $t2 ) / $iterations ) * 1000;

my $nf_held = $nf_checks ? $nf_checks->held : undef;

printf "500 mixed-status holds (+50 on a not-for-loan item), %d iterations:\n", $iterations;
printf "Old C4::Reserves::CheckReserves: %.3f ms/call\n", $old_ms;
printf "Optimized held():              %.3f ms/call\n", $new_ms;
printf "Speedup: %.2fx\n", $old_ms / $new_ms if $new_ms > 0;
printf "not-for-loan item held: %s\n", ( defined $nf_held ? $nf_held->status : 'undef' );

$schema->storage->txn_rollback;
