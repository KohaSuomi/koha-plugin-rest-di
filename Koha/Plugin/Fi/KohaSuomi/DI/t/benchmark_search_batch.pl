#!/usr/bin/perl
use Modern::Perl;
use Koha::Database;
use C4::Context;
use Koha::Biblios;
use Koha::Items;
use Time::HiRes qw(time);

use Koha::Plugin::Fi::KohaSuomi::DI::Koha::Biblio::Availability::Search;

my $schema = Koha::Database->new->schema;
$schema->storage->txn_begin;

my $biblio = Koha::Biblios->search( {}, { rows => 1 } )->next;
die "No biblio found\n" unless $biblio;

my $avail = Koha::Plugin::Fi::KohaSuomi::DI::Koha::Biblio::Availability::Search->new( { biblio => $biblio } );

my $iterations = 5;
my $t0 = time();
for ( 1 .. $iterations ) {
    $avail->in_opac( {} );
}
my $t1 = time();
printf "Biblio %d search availability: %.3f ms/call (%d iters)\n",
    $biblio->biblionumber, ( ( $t1 - $t0 ) / $iterations ) * 1000, $iterations;

$schema->storage->txn_rollback;
