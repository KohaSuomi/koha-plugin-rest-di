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

# Use existing data instead of build_sample_item to avoid savepoint issues.
my ( $itemnumber, $biblionumber, $homebranch ) = $dbh->selectrow_array(
    q{SELECT itemnumber, biblionumber, homebranch FROM items LIMIT 1}
);
die "No items found in database\n" unless $itemnumber;

my $patrons = $dbh->selectall_arrayref(
    q{SELECT borrowernumber, branchcode FROM borrowers LIMIT 10},
    { Slice => {} }
);
die "No borrowers found in database\n" unless @$patrons;

my @branches = map { $_->{branchcode} } @$patrons;
@branches = ( $homebranch ) unless @branches;

for ( my $i = 1; $i <= 500; $i++ ) {
    my $p = $patrons->[ $i % scalar(@$patrons) ];
    my $branch = $branches[ $i % scalar(@branches) ];
    $dbh->do(
        q|INSERT INTO reserves (borrowernumber, biblionumber, branchcode, priority, reservedate, found, itemnumber, suspend) VALUES (?,?,?,?,NOW(),NULL,NULL,0)|,
        undef,
        $p->{borrowernumber},
        $biblionumber,
        $branch,
        $i
    );
}

C4::Context->set_preference( 'AllowItemsOnHoldCheckoutSIP', 0 );
C4::Context->set_preference( 'AllowItemsOnHoldCheckoutSCO', 0 );
C4::Context->set_preference( 'LocalHoldsPriority', 'GiveLibraryGroup' );
C4::Context->set_preference( 'LocalHoldsPriorityMaxHolds', 20 );
C4::Context->set_preference( 'LocalHoldsPriorityMinItems', 3 );

my $item = Koha::Items->find($itemnumber);
my $checks = Koha::Plugin::Fi::KohaSuomi::DI::Koha::Availability::Checks::Item->new($item);

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

printf "500 biblio-level holds across branches, LocalHoldsPriority=GiveLibraryGroup, %d iterations:\n", $iterations;
printf "Old C4::Reserves::CheckReserves: %.3f ms/call\n", $old_ms;
printf "Optimized held():              %.3f ms/call\n", $new_ms;
printf "Speedup: %.2fx\n", $old_ms / $new_ms if $new_ms > 0;

$schema->storage->txn_rollback;
