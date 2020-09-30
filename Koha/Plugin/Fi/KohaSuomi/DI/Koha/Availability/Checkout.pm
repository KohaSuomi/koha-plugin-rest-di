package Koha::Plugin::Fi::KohaSuomi::DI::Koha::Availability::Checkout;

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

use Koha::Plugin::Fi::KohaSuomi::DI::Koha::Item::Availability::Checkout;

use Koha::Plugin::Fi::KohaSuomi::DI::Koha::Exceptions;

sub new {
    my ($class, $params) = @_;

    my $self = {};

    bless $self, $class;
}

sub item {
    my ($self, $params) = @_;

    return Koha::Plugin::Fi::KohaSuomi::DI::Koha::Item::Availability::Checkout->new($params);
}

1;
