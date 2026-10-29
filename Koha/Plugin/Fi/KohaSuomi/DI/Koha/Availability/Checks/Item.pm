package Koha::Plugin::Fi::KohaSuomi::DI::Koha::Availability::Checks::Item;

# Copyright 2016 Koha-Suomi Oy
# Copyright 2019 University of Helsinki (The National Library Of Finland)
#
# This file is part of Koha
#
# Koha is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version.
#
# Koha is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with Koha; if not, see <http://www.gnu.org/licenses>.

use Modern::Perl;

use base qw(Koha::Plugin::Fi::KohaSuomi::DI::Koha::Availability::Checks);

use C4::Circulation;
use C4::Context;
use C4::Reserves;

use Koha::AuthorisedValues;
use Koha::Database;
use Koha::Hold::HoldsQueueItems;
use Koha::DateUtils qw( dt_from_string );
use Koha::ItemTypes;
use Koha::Items;
use Koha::Item::Transfers;

use Koha::Plugin::Fi::KohaSuomi::DI::Koha::Exceptions::Item;
use Koha::Plugin::Fi::KohaSuomi::DI::Koha::Exceptions::ItemType;

sub new {
    my ($class, $item) = @_;

    unless ($item) {
        Koha::Plugin::Fi::KohaSuomi::DI::Koha::Exceptions::MissingParameter->throw(
            error => 'Class must be instantiated by providing a Koha::Item object.'
        );
    }
    unless (ref($item) eq 'Koha::Item') {
        Koha::Plugin::Fi::KohaSuomi::DI::Koha::Exceptions::BadParameter->throw(
            error => 'Item must be a Koha::Item object.'
        );
    }

    my $self = {
        item => $item,
    };

    bless $self, $class;
}

=head3 checked_out

Returns Koha::Plugin::Fi::KohaSuomi::DI::Koha::Exceptions::Item::CheckedOut if item is checked out.

=cut

sub checked_out {
    my ($self, $issue) = @_;

    $issue ||= $self->item->checkout;
    if (ref($issue) eq 'Koha::Checkout') {
        $issue = $issue->unblessed;
        $issue->{date_due} = dt_from_string($issue->{date_due});
    }
    if ($issue) {
        return Koha::Plugin::Fi::KohaSuomi::DI::Koha::Exceptions::Item::CheckedOut->new(
            borrowernumber => 0+$issue->{borrowernumber},
            due_date => $issue->{date_due}->strftime('%F %T'),
        );
    }
    return;
}

=head3 checked_out

Returns Koha::Plugin::Fi::KohaSuomi::DI::Koha::Exceptions::Checkout::Fee if checking out an item will cause
a checkout fee.

Koha::Plugin::Fi::KohaSuomi::DI::Koha::Exceptions::Checkout::Fee additional fields:
  amount                # defines the amount of checkout fee

=cut

sub checkout_fee {
    my ($self, $patron) = @_;

    my ($rentalCharge) = C4::Circulation::GetIssuingCharges
    (
        $self->item->itemnumber,
        $patron ? $patron->borrowernumber : undef
    );
    if ($rentalCharge > 0){
        return Koha::Plugin::Fi::KohaSuomi::DI::Koha::Exceptions::Checkout::Fee->new(
            amount => sprintf("%.02f", $rentalCharge),
        );
    }
    return;
}

=head3 damaged

Returns Koha::Plugin::Fi::KohaSuomi::DI::Koha::Exceptions::Item::Damaged if item is damaged and holds are not
allowed on damaged items.

=cut

sub damaged {
    my ($self) = @_;

    if ($self->item->damaged
        && !C4::Context->preference('AllowHoldsOnDamagedItems')) {
        my $av = Koha::AuthorisedValues->search({
            category => 'DAMAGED',
            authorised_value => $self->item->damaged
        });
        my $code = $av->count ? $av->next->lib : '';
        return Koha::Plugin::Fi::KohaSuomi::DI::Koha::Exceptions::Item::Damaged->new(
            status => 0+$self->item->damaged,
            code => $code,
        );
    }
    return;
}

=head3 from_another_library

Returns Koha::Plugin::Fi::KohaSuomi::DI::Koha::Exceptions::Item::FromAnotherLibrary if IndependentBranches is on,
and item is from another branch than the user currently logged in.

Koha::Exceptions::Item::FromAnotherLibrary additional fields:
  from_library              # item's library (according to HomeOrHoldingBranch)
  current_library           # the library of logged-in user

=cut

sub from_another_library {
    my ($self) = @_;

    my $item = $self->item;
    if (C4::Context->preference("IndependentBranches")) {
        return unless my $userenv = C4::Context->userenv;
        unless (C4::Context->IsSuperLibrarian()) {
            my $homeorholding = C4::Context->preference("HomeOrHoldingBranch");
            if ($userenv->{branch} && $item->$homeorholding ne $userenv->{branch}){
                return Koha::Plugin::Fi::KohaSuomi::DI::Koha::Exceptions::Item::FromAnotherLibrary->new(
                        from_library => $item->$homeorholding,
                        current_library => $userenv->{branch},
                );
            }
        }
    }
    return;
}

=head3 held

Returns Koha::Plugin::Fi::KohaSuomi::DI::Koha::Exceptions::Item::Held item is held.

Koha::Exceptions::Item::Held additional fields:
  borrowernumber              # patron with the hold
  status                      # hold status

=cut

sub held {
    my ($self) = @_;

    my $item = $self->item;

    # Allow disabling the optimized path for testing/comparison on a server.
    # Set environment variable REST_DI_DISABLE_HELD_OPTIMIZATION=1 or system
    # preference RESTDIDisableHeldOptimization=1 to fall back to the original
    # C4::Reserves::CheckReserves implementation.
    if ( $ENV{REST_DI_DISABLE_HELD_OPTIMIZATION}
        || C4::Context->preference('RESTDIDisableHeldOptimization') ) {
        if ( my ( $s, $reserve ) = C4::Reserves::CheckReserves($item) ) {
            if (!$reserve) {
                return;
            }
            if ( $s eq 'Waiting' || $s eq 'Processing'
                || ( $reserve->{'itemnumber'} == $item->itemnumber
                    && !C4::Context->preference('AllowItemsOnHoldCheckoutSIP')
                    && !C4::Context->preference('AllowItemsOnHoldCheckoutSCO') ) ) {
                return Koha::Plugin::Fi::KohaSuomi::DI::Koha::Exceptions::Item::Held->new(
                    borrowernumber => 0 + $reserve->{'borrowernumber'},
                    status        => $s,
                );
            }
        }
        return;
    }

    # Mirror C4::Reserves::CheckReserves early returns so that items that are
    # not trappable (e.g. on-order / not-for-loan items) are not reported as
    # held. This is especially important for on-order items that already have
    # holds placed on them.
    return if ( $item->damaged && !C4::Context->preference('AllowHoldsOnDamagedItems') );

    my @SkipHoldTrapOnNotForLoanValue = split( '\\|', C4::Context->preference('SkipHoldTrapOnNotForLoanValue') );
    return if grep { $_ eq $item->notforloan } @SkipHoldTrapOnNotForLoanValue;

    my $dont_trap = C4::Context->preference('TrapHoldsOnOrder') ? $item->notforloan > 0 : $item->notforloan;
    if ( !$dont_trap ) {
        my $effective_item_type = $item->effective_itemtype;
        our %ITEMTYPE_NOTFORLOAN_CACHE;
        my $itemtype_notforloan;
        if ( exists $ITEMTYPE_NOTFORLOAN_CACHE{$effective_item_type} ) {
            $itemtype_notforloan = $ITEMTYPE_NOTFORLOAN_CACHE{$effective_item_type};
        } else {
            my $item_type = Koha::ItemTypes->find($effective_item_type);
            $itemtype_notforloan = $item_type ? $item_type->notforloan : 0;
            $ITEMTYPE_NOTFORLOAN_CACHE{$effective_item_type} = $itemtype_notforloan;
        }
        return if $itemtype_notforloan;
    } else {
        return;
    }

    my $allow_sip = C4::Context->preference('AllowItemsOnHoldCheckoutSIP');
    my $allow_sco = C4::Context->preference('AllowItemsOnHoldCheckoutSCO');

    my $dbh = C4::Context->dbh;

    # Found holds (Waiting / Processing / Transferred). Use a direct, cached
    # query to avoid DBIC overhead and the full CheckReserves scan.
    my $found_sth = $dbh->prepare_cached(q{
        SELECT borrowernumber, found
        FROM reserves
        WHERE itemnumber = ? AND found IN ('W','P','T') AND suspend = 0
        LIMIT 1
    });
    $found_sth->execute( 0 + $item->itemnumber );
    my ( $found_bn, $found_status_raw ) = $found_sth->fetchrow_array;
    $found_sth->finish;

    if ( defined $found_status_raw ) {
        my $status = $found_status_raw eq 'W' ? 'Waiting'
                   : $found_status_raw eq 'P' ? 'Processing'
                   : 'Transferred';

        # Waiting and Processing holds always make the item held.
        if ( $status eq 'Waiting' || $status eq 'Processing' ) {
            return Koha::Plugin::Fi::KohaSuomi::DI::Koha::Exceptions::Item::Held->new(
                borrowernumber => 0 + $found_bn,
                status        => $status,
            );
        }

        # Transferred holds make the item held only when checking out an
        # item on hold is not allowed.
        if ( !$allow_sip && !$allow_sco ) {
            return Koha::Plugin::Fi::KohaSuomi::DI::Koha::Exceptions::Item::Held->new(
                borrowernumber => 0 + $found_bn,
                status        => $status,
            );
        }
    }

    # Candidate (not yet found) holds only matter when checking out an item on
    # hold is disallowed.
    if ( !$allow_sip && !$allow_sco ) {
        # Item-level holds.
        my $item_hold_sth = $dbh->prepare_cached(q{
            SELECT borrowernumber
            FROM reserves
            WHERE itemnumber = ? AND found IS NULL AND suspend = 0
            ORDER BY priority
            LIMIT 1
        });
        $item_hold_sth->execute( 0 + $item->itemnumber );
        my ($item_hold_bn) = $item_hold_sth->fetchrow_array;
        $item_hold_sth->finish;

        if ( defined $item_hold_bn ) {
            return Koha::Plugin::Fi::KohaSuomi::DI::Koha::Exceptions::Item::Held->new(
                borrowernumber => 0 + $item_hold_bn,
                status        => 'Reserved',
            );
        }

        # When the real-time holds queue is maintained, use it to detect
        # biblio-level holds assigned to this item.
        if ( C4::Context->preference('RealTimeHoldsQueue') ) {
            my $queue_bn;
            eval {
                my $queue_item = Koha::Hold::HoldsQueueItems->find( $item->itemnumber );
                $queue_bn = $queue_item ? $queue_item->borrowernumber : undef;
            };
            if ( defined $queue_bn ) {
                return Koha::Plugin::Fi::KohaSuomi::DI::Koha::Exceptions::Item::Held->new(
                    borrowernumber => 0 + $queue_bn,
                    status        => 'Reserved',
                );
            }
        } else {
            # Preserve original behaviour when the real-time queue is off.
            if ( my ( $s, $reserve ) = C4::Reserves::CheckReserves($item) ) {
                if ( $reserve && $reserve->{'itemnumber'} == $item->itemnumber ) {
                    return Koha::Plugin::Fi::KohaSuomi::DI::Koha::Exceptions::Item::Held->new(
                        borrowernumber => 0 + $reserve->{'borrowernumber'},
                        status        => $s,
                    );
                }
            }
        }
    }

    return;
}

=head3 held_by_patron

Returns Koha::Plugin::Fi::KohaSuomi::DI::Koha::Exceptions::Item::AlreadyHeldForThisPatron if item is already
held by given patron.

OPTIONAL PARAMETERS
holds       # list of Koha::Hold objects to inspect the item's held-status from.
            # If not given, a query is made for selecting the holds from database.
            # Useful in optimizing biblio-level availability by selecting all holds
            # of a biblio and then passing it for this function instead of querying
            # reserves table multiple times for each item.

=cut

sub held_by_patron {
    my ($self, $patron, $params) = @_;

    my $item = $self->item;
    my $holds;
    if (!exists $params->{'holds'}) {
        $holds = Koha::Holds->search({
            borrowernumber => 0+$patron->borrowernumber,
            itemnumber => 0+$item->itemnumber,
        })->count();
    } else {
        foreach my $hold (@{$params->{'holds'}}) {
            next unless $hold->itemnumber;
            if ($hold->itemnumber == $item->itemnumber) {
                $holds++;
            }
        }
    }
    if ($holds) {
        return Koha::Plugin::Fi::KohaSuomi::DI::Koha::Exceptions::Item::AlreadyHeldForThisPatron->new
    }
    return;
}

=head3 high_hold

Returns Koha::Plugin::Fi::KohaSuomi::DI::Koha::Exceptions::Item::HighHolds if item is a high-held item and
decreaseLoanHighHolds is enabled.

=cut

sub high_hold {
    my ($self, $patron) = @_;

    return unless C4::Context->preference('decreaseLoanHighHolds');

    my $item = $self->item;
    my $check = C4::Circulation::checkHighHolds($item, $patron);

    if ($check->{exceeded}) {
        return Koha::Plugin::Fi::KohaSuomi::DI::Koha::Exceptions::Item::HighHolds->new(
            num_holds => 0+$check->{outstanding},
            duration => $check->{duration},
            returndate => $check->{due_date}->strftime('%F %T'),
        );
    }
    return;
}

=head3 lost

Returns Koha::Plugin::Fi::KohaSuomi::DI::Koha::Exceptions::Item::Lost if item is lost.

=cut

sub lost {
    my ($self) = @_;

    my $item = $self->item;
    if ($self->item->itemlost) {
        my $av = Koha::AuthorisedValues->search({
            category => 'LOST',
            authorised_value => $item->itemlost
        });
        my $code = $av->count ? $av->next->lib : '';
        return Koha::Plugin::Fi::KohaSuomi::DI::Koha::Exceptions::Item::Lost->new(
            status => 0+$item->itemlost,
            code => $code,
        );
    }
    return;
}

=head3 notforloan

Returns Koha::Plugin::Fi::KohaSuomi::DI::Koha::Exceptions::Item::NotForLoan if item is not for loan, and
additionally Koha::Plugin::Fi::KohaSuomi::DI::Koha::Exceptions::ItemType::NotForLoan if itemtype is not for loan.

=cut

sub notforloan {
    my ($self) = @_;

    my $item = $self->item;
    my $effective_itemtype = $item->effective_itemtype // '';

    my $cache = Koha::Caches->get_instance('availability');
    my $cached = $cache->get_from_cache('itemtype-'.$effective_itemtype);
    my $itemtype;
    if ($cached) {
        delete $cached->{translated_description};
        $itemtype = Koha::ItemType->new->set($cached);
    } else {
        $itemtype = Koha::ItemTypes->find($effective_itemtype);
        $cache->set_in_cache('itemtype-'.$effective_itemtype,
                            $itemtype->unblessed, { expiry => 10 }) if $itemtype;
    }

    if ($item->notforloan != 0 || $itemtype && $itemtype->notforloan != 0) {
        my $code = '';
        if ($item->notforloan != 0) {
            my $av = Koha::AuthorisedValues->search({
                category => 'NOT_LOAN',
                authorised_value => $item->notforloan
            });
            if ($av->count) {
                $av = $av->next;
                $code = $av->lib_opac || $av->lib;
            }
        }
        if ($item->notforloan > 0) {
            return Koha::Plugin::Fi::KohaSuomi::DI::Koha::Exceptions::Item::NotForLoan->new(
                status => 0+$item->notforloan,
                code => $code,
            );
        } elsif ($itemtype && $itemtype->notforloan > 0) {
            return Koha::Plugin::Fi::KohaSuomi::DI::Koha::Exceptions::ItemType::NotForLoan->new(
                status => 0+$itemtype->notforloan,
                code => $itemtype->description,
                itemtype => $itemtype->itemtype,
            );
        } elsif ($item->notforloan < 0) {
            return Koha::Plugin::Fi::KohaSuomi::DI::Koha::Exceptions::Item::NotForLoan->new(
                status => 0+$item->notforloan,
                code => $code,
            );
        }
    }
    return;
}

=head3 onloan

Returns Koha::Plugin::Fi::KohaSuomi::DI::Koha::Exceptions::Item::CheckedOut if item is onloan.

This does not query issues table, but simply checks item's onloan-column.

=cut

sub onloan {
    my ($self) = @_;

    # This simply checks item's onloan-column to determine item's checked out
    # -status. Use C<checked_out> to perform an actual query for checkouts.
    if ($self->item->onloan) {
        return Koha::Plugin::Fi::KohaSuomi::DI::Koha::Exceptions::Item::CheckedOut->new;
    }
}

=head3 pickup_locations

Gets list of available pickup locations for item hold.

$context_cache is a hash ref used to store data between calls to avoid repeated checks.

Returns Koha::Plugin::Fi::KohaSuomi::DI::Koha::Exceptions::Item::PickupLocations.

=cut

sub pickup_locations {
    my ($self, $patron, $context_cache) = @_;

    my $pickup_libraries = Koha::Libraries->search({
        pickup_location => 1 })->unblessed;
    my $pickup_locations = [];
    my $filtered = Mojo::JSON->false;

    if (C4::Context->preference('UseBranchTransferLimits')) {
        my $limit_type = C4::Context->preference('BranchTransferLimitsType');
        my $limits = Koha::Item::Transfer::Limits->search({
            fromBranch  => $self->item->holdingbranch,
            $limit_type => $limit_type eq 'itemtype' ? ($self->item->effective_itemtype // '') : $self->item->ccode
        })->unblessed;

        foreach my $library (@$pickup_libraries) {
            if (!(grep { $library->{branchcode} eq $_->{toBranch} } @$limits)
                && $self->_pickup_location_allowed($library->{branchcode}, $patron, $context_cache)
            ) {
                push @{$pickup_locations}, $library->{branchcode};
            } else {
                $filtered = Mojo::JSON->true;
            }
        }
    } else {
        foreach my $library (@$pickup_libraries) {
            if ($self->_pickup_location_allowed($library->{branchcode}, $patron, $context_cache)) {
                push @{$pickup_locations}, $library->{branchcode};
            } else {
                $filtered = Mojo::JSON->true;
            }
        }
    }

    @$pickup_locations = sort { $a cmp $b } @$pickup_locations;
    return Koha::Plugin::Fi::KohaSuomi::DI::Koha::Exceptions::Item::PickupLocations->new(
        from_library => $self->item->holdingbranch,
        to_libraries => $pickup_locations,
        filtered => $filtered
    );
}

=head3 restricted

Returns Koha::Plugin::Fi::KohaSuomi::DI::Koha::Exceptions::Item::Restricted if item is restricted.

=cut

sub restricted {
    my ($self) = @_;

    if ($self->item->restricted) {
        return Koha::Plugin::Fi::KohaSuomi::DI::Koha::Exceptions::Item::Restricted->new;
    }
    return;
}

=head3 transfer

Returns Koha::Plugin::Fi::KohaSuomi::DI::Koha::Exceptions::Item::Transfer if item is in transfer.

Koha::Exceptions::Item::Transfer additional fields:
  from_library
  to_library
  datesent

=cut

sub transfer {
    my ($self) = @_;

    my $transfer = $self->item->get_transfer;
    if ($transfer) {
        return Koha::Plugin::Fi::KohaSuomi::DI::Koha::Exceptions::Item::Transfer->new(
            from_library => $transfer->frombranch,
            to_library => $transfer->tobranch,
            datesent => $transfer->datesent,
        );
    }
    return;
}

=head3 transfer_limit

Returns Koha::Plugin::Fi::KohaSuomi::DI::Koha::Exceptions::Item::CannotBeTransferred a transfer limit applies
for item.

Koha::Exceptions::Item::CannotBeTransferred additional parameters:
  from_library
  to_library

=cut

sub transfer_limit {
    my ($self, $to_branch) = @_;

    return unless C4::Context->preference('UseBranchTransferLimits');
    my $item = $self->item;
    my $limit_type = C4::Context->preference('BranchTransferLimitsType');
    my $code;
    if ($limit_type eq 'itemtype') {
        $code = $item->effective_itemtype // '';
    } elsif ($limit_type eq 'ccode') {
        $code = $item->ccode;
    } else {
        Koha::Plugin::Fi::KohaSuomi::DI::Koha::Exceptions::BadParameter->throw(
            error => 'System preference BranchTransferLimitsType has an'
            .' unrecognized value.'
        );
    }

    my $allowed = C4::Circulation::IsBranchTransferAllowed(
        $to_branch,
        $item->holdingbranch,
        $code
    );
    if (!$allowed) {
        return Koha::Plugin::Fi::KohaSuomi::DI::Koha::Exceptions::Item::CannotBeTransferred->new(
            from_library => $item->holdingbranch,
            to_library   => $to_branch,
        );
    }
    return;
}

=head3 unknown_barcode

Returns Koha::Plugin::Fi::KohaSuomi::DI::Koha::Exceptions::Item::UnknownBarcode if item has no barcode.

=cut

sub unknown_barcode {
    my ($self) = @_;

    my $item = $self->item;
    unless ($item->barcode) {
        return Koha::Plugin::Fi::KohaSuomi::DI::Koha::Exceptions::Item::UnknownBarcode->new;
    }
    return;
}

=head3 withdrawn

Returns Koha::Plugin::Fi::KohaSuomi::DI::Koha::Exceptions::Item::Withdrawn if item is withdrawn.

=cut

sub withdrawn {
    my ($self) = @_;

    if ($self->item->withdrawn) {
        return Koha::Plugin::Fi::KohaSuomi::DI::Koha::Exceptions::Item::Withdrawn->new;
    }
    return;
}

=head3 _pickup_library_allowed

  if ($self->_pickup_location_allowed($location, $patron, $context_cache))...

Checks if pickup location is allowed. $context_cache is a hash ref used to store data between calls to avoid repeated checks.

=cut

sub _pickup_location_allowed {
    my ($self, $location, $patron, $context_cache) = @_;

    if (!defined $context_cache->{can_place_hold_if_available_at_pickup}) {
        my $can_place = C4::Context->preference('OPACHoldsIfAvailableAtPickup');
        unless ($can_place || !$patron) {
            my @patron_categories = split ',', C4::Context->preference('OPACHoldsIfAvailableAtPickupExceptions');
            if (@patron_categories) {
                my $categorycode = $patron->categorycode;
                $can_place = grep { $_ eq $categorycode } @patron_categories;
            }
        }
        $context_cache->{can_place_hold_if_available_at_pickup} = $can_place;
    }
    return 1 if $context_cache->{can_place_hold_if_available_at_pickup};

    # Filter out pickup locations with available items
    if (!defined $context_cache->{items_available_by_location}->{$location}) {
        $context_cache->{items_available_by_location}->{$location} = Koha::Items->search(
            {
                'me.biblionumber' => $self->item->biblionumber,
                'me.holdingbranch' => $location,
                'me.itemlost' => 0,
                'me.damaged' => 0,
                'issue.itemnumber' => undef
            },
            { join => 'issue' }
        )->count;
    }
    return $context_cache->{items_available_by_location}->{$location} ? 0 : 1;
}

=head3 recalled

Returns Koha::Plugin::Fi::KohaSuomi::DI::Koha::Exceptions::Item::Recalled if item has been recalled.

=cut

sub recalled {
    my ($self) = @_;

    if ($self->item->recall) {
        return Koha::Plugin::Fi::KohaSuomi::DI::Koha::Exceptions::Item::Recalled->new;
    }
}

1;
