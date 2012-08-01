use strict;
use warnings;
use Devel::CallParser;
use Devel::CallChecker;
use IO::File;
use ExtUtils::MakeMaker;

IO::File->new('callchecker0.h', 'w')->print(
    Devel::CallChecker::callchecker0_h,
);

IO::File->new('callparser.h', 'w')->print(
    Devel::CallParser::callparser0_h,
);

WriteMakefile(
    NAME => 'Gather::Once',
);
