#!/usr/bin/perl
use Modern::Perl;
use Getopt::Long qw(:config no_ignore_case);
use Koha::Database;
use C4::Context;
use Koha::DateUtils qw( dt_from_string );

my ( $biblionumber, $count, $itemnumber, $branchcode, $found, $help );

GetOptions(
    'biblio=i'   => \$biblionumber,
    'count=i'    => \$count,
    'item=i'     => \$itemnumber,
    'branch=s'   => \$branchcode,
    'found=s'    => \$found,
    'help'       => \$help,
) or die "Error in command line arguments\n";

if ($help || !defined $biblionumber || !defined $count) {
    print <<'EOF';
Usage: populate_holds.pl --biblio ID --count N [options]

Options:
  --biblio ID      Biblionumber to populate holds for (required)
  --count N        Number of holds to create (required)
  --item ID        Itemnumber for item-level holds (optional)
  --branch CODE    Pickup branch (defaults to item's homebranch or first branch)
  --found STATUS   Found status: W, P, T, or empty (default: empty)
  --help           Show this help
EOF
    exit 0;
}

my $schema = Koha::Database->new->schema;
my $dbh    = C4::Context->dbh;

my $homebranch = $branchcode;
if ( !defined $homebranch && defined $itemnumber ) {
    ($homebranch) = $dbh->selectrow_array(
        q{SELECT homebranch FROM items WHERE itemnumber = ?}, undef, $itemnumber );
}
if ( !defined $homebranch ) {
    ($homebranch) = $dbh->selectrow_array(q{SELECT branchcode FROM branches LIMIT 1});
}
die "Could not determine branchcode\n" unless defined $homebranch;

my $priority = 1;
for ( my $i = 0; $i < $count; $i++ ) {
    my ( $borrowernumber, $patron_branch ) = $dbh->selectrow_array(
        q{SELECT borrowernumber, branchcode FROM borrowers ORDER BY RAND() LIMIT 1}
    );
    die "No borrowers found in database\n" unless defined $borrowernumber;

    my $pickup_branch = $branchcode || $patron_branch || $homebranch;

    $dbh->do(
        q|INSERT INTO reserves (borrowernumber, biblionumber, itemnumber, branchcode, priority, reservedate, found, suspend)
          VALUES (?,?,?,?,NOW(),?,?,0)|,
        undef,
        $borrowernumber,
        $biblionumber,
        $itemnumber,
        $pickup_branch,
        $priority++,
        ( defined $found && $found ne '' ? $found : undef )
    );
}

print "Created $count holds for biblio $biblionumber\n";
print "Transaction not committed; run inside a test harness or commit manually.\n";