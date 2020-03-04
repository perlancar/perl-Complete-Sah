package Complete::Sah;

# AUTHORITY
# DATE
# DIST
# VERSION

use 5.010001;
use strict;
use warnings;
use Log::ger;

use Complete::Common qw(:all);
use Complete::Util qw(combine_answers complete_array_elem hashify_answer);

our %SPEC;
require Exporter;
our @ISA       = qw(Exporter);
our @EXPORT_OK = qw(complete_from_schema);

$SPEC{':package'} = {
    v => 1.1,
    summary => 'Sah-related completion routines',
};

$SPEC{complete_from_schema} = {
    v => 1.1,
    summary => 'Complete a value from schema',
    description => <<'_',

Employ some heuristics to complete a value from Sah schema. For example, if
schema is `[str => in => [qw/new open resolved rejected/]]`, then we can
complete from the `in` clause. Or for something like `[int => between => [1,
20]]` we can complete using values from 1 to 20.

_
    args => {
        schema => {
            description => <<'_',

Will be normalized, unless when `schema_is_normalized` is set to true, in which
case schema must already be normalized.

_
            req => 1,
        },
        schema_is_normalized => {
            schema => 'bool',
            default => 0,
        },
        word => {
            schema => [str => default => ''],
            req => 1,
        },
    },
};
sub complete_from_schema {
    my %args = @_;
    my $sch  = $args{schema};
    my $word = $args{word} // "";

    unless ($args{schema_is_normalized}) {
        require Data::Sah::Normalize;
        $sch =Data::Sah::Normalize::normalize_schema($sch);
    }

    my $fres;
    log_trace("[compsah] entering complete_from_schema, word=<%s>, schema=%s", $word, $sch);

    my ($type, $cs) = @{$sch};

    # schema might be based on other schemas, if that is the case, let's try to
    # look at Sah::SchemaR::* module to quickly find the base type
    unless ($type =~ /\A(all|any|array|bool|buf|cistr|code|date|duration|float|hash|int|num|obj|re|str|undef)\z/) {
        no strict 'refs';
        my $pkg = "Sah::SchemaR::$type";
        (my $pkg_pm = "$pkg.pm") =~ s!::!/!g;
        eval { require $pkg_pm; 1 };
        if ($@) {
            log_trace("[compsah] couldn't load schema module %s: %s, skipped", $pkg, $@);
            goto RETURN_RES;
        }
        my $rsch = ${"$pkg\::rschema"};
        $type = $rsch->[0];
        # let's just merge everything, for quick checking of clause
        $cs = {};
        for my $cs0 (@{ $rsch->[1] // [] }) {
            for (keys %$cs0) {
                $cs->{$_} = $cs0->{$_};
            }
        }
        log_trace("[compsah] retrieving schema from module %s, base type=%s", $pkg, $type);
    }

    my $static;
    my $words;
    my $summaries;
    eval {
        if (my $xcomp = $cs->{'x.completion'}) {
            require Module::Installed::Tiny;
            my $comp;
            if (ref($xcomp) eq 'CODE') {
                $comp = $xcomp;
            } else {
                my ($submod, $xcargs);
                if (ref($xcomp) eq 'ARRAY') {
                    $submod = $xcomp->[0];
                    $xcargs = $xcomp->[1];
                } else {
                    $submod = $xcomp;
                    $xcargs = {};
                }
                my $mod = "Perinci::Sub::XCompletion::$submod";
                if (Module::Installed::Tiny::module_installed($mod)) {
                    log_trace("[compsah] loading module %s ...", $mod);
                    my $mod_pm = $mod; $mod_pm =~ s!::!/!g; $mod_pm .= ".pm";
                    require $mod_pm;
                    my $fref = \&{"$mod\::gen_completion"};
                    log_trace("[compsah] invoking %s's gen_completion(%s) ...", $mod, $xcargs);
                    $comp = $fref->(%$xcargs);
                } else {
                    log_trace("[compsah] module %s is not installed, skipped", $mod);
                }
            }
            if ($comp) {
                log_trace("[compsah] using arg completion routine from schema's 'x.completion' attribute");
                $fres = $comp->(
                    %{$args{extras} // {}},
                    word=>$word, arg=>$args{arg}, args=>$args{args});
                return; # from eval
                }
            }

        if ($cs->{is} && !ref($cs->{is})) {
            log_trace("[compsah] adding completion from schema's 'is' clause");
            push @$words, $cs->{is};
            push @$summaries, undef;
            $static++;
            return; # from eval. there should not be any other value
        }
        if ($cs->{in}) {
            log_trace("[compsah] adding completion from schema's 'in' clause");
            for my $i (0..$#{ $cs->{in} }) {
                next if ref $cs->{in}[$i];
                push @$words    , $cs->{in}[$i];
                push @$summaries, $cs->{'x.in.summaries'} ? $cs->{'x.in.summaries'}[$i] : undef;
            }
            $static++;
            return; # from eval. there should not be any other value
        }
        if ($cs->{'examples'}) {
            log_trace("[compsah] adding completion from schema's 'examples' clause");
            for my $eg (@{ $cs->{'examples'} }) {
                if (ref $eg eq 'HASH') {
                    next unless !exists($eg->{valid}) || $eg->{valid};
                    next unless defined $eg->{value};
                    next if ref $eg->{value};
                    push @$words, $eg->{value};
                    push @$summaries, $eg->{summary};
                } else {
                    next unless defined $eg;
                    next if ref $eg;
                    push @$words, $eg;
                    push @$summaries, undef;
                }
            }
            #$static++;
            #return; # from eval. there should not be any other value
        }
        if ($type eq 'any') {
            # because currently Data::Sah::Normalize doesn't recursively
            # normalize schemas in 'of' clauses, etc.
            require Data::Sah::Normalize;
            if ($cs->{of} && @{ $cs->{of} }) {

                $fres = combine_answers(
                    grep { defined } map {
                        complete_from_schema(schema=>$_, word => $word)
                    } @{ $cs->{of} }
                );
                goto RETURN_RES; # directly return result
            }
        }
        if ($type eq 'bool') {
            log_trace("[compsah] adding completion from possible values of bool");
            push @$words, 0, 1;
            push @$summaries, undef, undef;
            $static++;
            return; # from eval
        }
        if ($type eq 'int') {
            my $limit = 100;
            if ($cs->{between} &&
                    $cs->{between}[0] - $cs->{between}[0] <= $limit) {
                log_trace("[compsah] adding completion from schema's 'between' clause");
                for ($cs->{between}[0] .. $cs->{between}[1]) {
                    push @$words, $_;
                    push @$summaries, undef;
                }
                $static++;
            } elsif ($cs->{xbetween} &&
                         $cs->{xbetween}[0] - $cs->{xbetween}[0] <= $limit) {
                log_trace("[compsah] adding completion from schema's 'xbetween' clause");
                for ($cs->{xbetween}[0]+1 .. $cs->{xbetween}[1]-1) {
                    push @$words, $_;
                    push @$summaries, undef;
                }
                $static++;
            } elsif (defined($cs->{min}) && defined($cs->{max}) &&
                         $cs->{max}-$cs->{min} <= $limit) {
                log_trace("[compsah] adding completion from schema's 'min' & 'max' clauses");
                for ($cs->{min} .. $cs->{max}) {
                    push @$words, $_;
                    push @$summaries, undef;
                }
                $static++;
            } elsif (defined($cs->{min}) && defined($cs->{xmax}) &&
                         $cs->{xmax}-$cs->{min} <= $limit) {
                log_trace("[compsah] adding completion from schema's 'min' & 'xmax' clauses");
                for ($cs->{min} .. $cs->{xmax}-1) {
                    push @$words, $_;
                    push @$summaries, undef;
                }
                $static++;
            } elsif (defined($cs->{xmin}) && defined($cs->{max}) &&
                         $cs->{max}-$cs->{xmin} <= $limit) {
                log_trace("[compsah] adding completion from schema's 'xmin' & 'max' clauses");
                for ($cs->{xmin}+1 .. $cs->{max}) {
                    push @$words, $_;
                    push @$summaries, undef;
                }
                $static++;
            } elsif (defined($cs->{xmin}) && defined($cs->{xmax}) &&
                         $cs->{xmax}-$cs->{xmin} <= $limit) {
                log_trace("[compsah] adding completion from schema's 'xmin' & 'xmax' clauses");
                for ($cs->{xmin}+1 .. $cs->{xmax}-1) {
                    push @$words, $_;
                    push @$summaries, undef;
                }
                $static++;
            } elsif (length($word) && $word !~ /\A-?\d*\z/) {
                log_trace("[compsah] word not an int");
                $words = [];
                $summaries = [];
            } else {
                # do a digit by digit completion
                $words = [];
                $summaries = [];
                for my $sign ("", "-") {
                    for ("", 0..9) {
                        my $i = $sign . $word . $_;
                        next unless length $i;
                        next unless $i =~ /\A-?\d+\z/;
                        next if $i eq '-0';
                        next if $i =~ /\A-?0\d/;
                        next if $cs->{between} &&
                            ($i < $cs->{between}[0] ||
                                 $i > $cs->{between}[1]);
                        next if $cs->{xbetween} &&
                            ($i <= $cs->{xbetween}[0] ||
                                 $i >= $cs->{xbetween}[1]);
                        next if defined($cs->{min} ) && $i <  $cs->{min};
                        next if defined($cs->{xmin}) && $i <= $cs->{xmin};
                        next if defined($cs->{max} ) && $i >  $cs->{max};
                        next if defined($cs->{xmin}) && $i >= $cs->{xmax};
                        push @$words, $i;
                        push @$summaries, undef;
                    }
                }
            }
            return; # from eval
        }
        if ($type eq 'float') {
            if (length($word) && $word !~ /\A-?\d*(\.\d*)?\z/) {
                log_trace("[compsah] word not a float");
                $words = [];
                $summaries = [];
            } else {
                $words = [];
                $summaries = [];
                for my $sig ("", "-") {
                    for ("", 0..9,
                         ".0",".1",".2",".3",".4",".5",".6",".7",".8",".9") {
                        my $f = $sig . $word . $_;
                        next unless length $f;
                        next unless $f =~ /\A-?\d+(\.\d+)?\z/;
                        next if $f eq '-0';
                        next if $f =~ /\A-?0\d\z/;
                        next if $cs->{between} &&
                            ($f < $cs->{between}[0] ||
                                 $f > $cs->{between}[1]);
                        next if $cs->{xbetween} &&
                            ($f <= $cs->{xbetween}[0] ||
                                 $f >= $cs->{xbetween}[1]);
                        next if defined($cs->{min} ) && $f <  $cs->{min};
                        next if defined($cs->{xmin}) && $f <= $cs->{xmin};
                        next if defined($cs->{max} ) && $f >  $cs->{max};
                        next if defined($cs->{xmin}) && $f >= $cs->{xmax};
                        push @$words, $f;
                        push @$summaries, undef;
                    }
                }
                my @orders = sort { $words->[$a] cmp $words->[$b] }
                    0..$#{$words};
                my $words     = [map {$words->[$_]    } @orders];
                my $summaries = [map {$summaries->[$_]} @orders];
            }
            return; # from eval
        }
    }; # eval
    log_trace("[compsah] complete_from_schema died: %s", $@) if $@;

    my $replace_map;
  GET_REPLACE_MAP:
    {
        last unless $cs->{prefilters};
        # TODO: make replace_map in Complete::Util equivalent as
        # Str::replace_map's map.
        for my $entry (@{ $cs->{prefilters} }) {
            next unless ref $entry eq 'ARRAY';
            next unless $entry->[0] eq 'Str::replace_map';
            $replace_map = {};
            for my $k (keys %{ $entry->[1]{map} }) {
                my $v = $entry->[1]{map}{$k};
                $replace_map->{$v} = [$k];
            }
            last;
        }
    }

    goto RETURN_RES unless $words;
    $fres = hashify_answer(
        complete_array_elem(
            array=>$words,
            summaries=>$summaries,
            word=>$word,
            (replace_map => $replace_map) x !!$replace_map,
        ),
        {static=>$static && $word eq '' ? 1:0},
    );

  RETURN_RES:
    log_trace("[compsah] leaving complete_from_schema, result=%s", $fres);
    $fres;
}

1;
#ABSTRACT:

=head1 SYNOPSIS

 use Complete::Sah qw(complete_from_schema);
 my $res = complete_from_schema(word => 'a', schema=>[str => {in=>[qw/apple apricot banana/]}]);
 # -> {words=>['apple', 'apricot'], static=>0}

=cut
