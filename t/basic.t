use strict;
use warnings;
use Test::More 0.89;

use Gather::Once
    block => 'with',
    take  => 'iff',
    topicalise => 1,
    predicate  => sub {
        warn "$_[0] == $_[1]";
        $_[0] == $_[1];
    };

my $n = 42;

my @ret = with ($n) {
    warn 42;
    iff (42) { 23 };
    warn 23;
    42;
};

diag explain \@ret;

use Gather::Once
    block => 'moo',
    take  => 'iff_',
    predicate  => sub {
        warn scalar @_;
        warn "$_[0]";
        !!$_[0]
    };

=for later
iff_ (42) { };
=cut

my @ret_ = moo {
    iff_ (42) { 1, 2, 3 };
};

diag explain \@ret_;

done_testing;
