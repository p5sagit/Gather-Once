use strict;
use warnings;

package Gather::Once;

use Devel::CallParser;

use XSLoader;
XSLoader::load(__PACKAGE__);

use Carp 'croak';
use Sub::Install 'install_sub';

sub import {
    my ($class, %args) = @_;
    my $caller = caller;

    my $gather = sub { croak "$args{block} called as a function" };
    my $take   = sub { croak "$args{take} called as a function"  };

    install_sub({
        code => $gather,
        into => $caller,
        as   => $args{block},
    });

    install_sub({
        code => $take,
        into => $caller,
        as   => $args{take},
    });

    setup_gather_hook($gather, !!$args{topicalise});
    setup_take_hook($take, [$args{topicalise}, $args{predicate}]);
}

1;
