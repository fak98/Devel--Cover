# Copyright 2014, Paul Johnson (paul@pjcj.net)

# This software is free.  It is licensed under the same terms as Perl itself.

# The latest version of this software should be available from my homepage:
# http://www.pjcj.net

package Devel::Cover::Collection;

use 5.16.0;
use warnings;

# VERSION

use Devel::Cover::DB::IO::JSON;
use Devel::Cover::Dumper;

use Capture::Tiny      "capture_merged";
use Parallel::Iterator "iterate_as_array";

use Class::XSAccessor ();
use Moo;
use namespace::clean;
use warnings FATAL => "all";  # be explicit since Moo sets this

my %A = (
    ro  => [ qw( bin_dir cpancover_dir cpanm_dir results_dir force outputfile
                 report timeout verbose workers ) ],
    rwp => [ qw( build_dirs build_dir modules )                         ],
    rw  => [ qw( )                                                      ],
);
while (my ($type, $names) = each %A) { has $_ => (is => $type) for @$names }

sub BUILDARGS {
    my $class = shift;
    my (%args) = @_;
    {
        build_dirs => [],
        cpanm_dir  => glob("~/.cpanm"),
        force      => 0,
        modules    => [],
        outputfile => "index.html",
        report     => "html_basic",
        timeout    => 900,  # fifteen minutes should be enough
        verbose    => 0,
        workers    => 0,
        %args,
    }
};

sub sys {
    my $self = shift;
    my (@command) = @_;
    my $output;
    $output = "-> @command\n" if $self->verbose;
    # TODO - check for failure
    $output .= capture_merged { system @command };
    $output
}

sub empty_cpanm_dir {
    my $self = shift;
    # TODO - not portable
    my $output = $self->sys("rm", "-rf", $self->cpanm_dir);
    say $output;
}

sub add_modules {
    my $self = shift;
    push @{$self->modules}, @_;
}

sub build_modules {
    my $self = shift;
    my @command = qw( cpanm --notest );
    push @command, "--force" if $self->force;
    for my $module (@{$self->modules}) {
        my $output = $self->sys(@command, $module);
        say $output;
    }
}

sub add_build_dirs {
    my $self = shift;
    push @{$self->build_dirs}, grep -d, glob $self->cpanm_dir . "/work/*/*";
}

sub run {
    my $self = shift;

    my $d = $self->build_dir;
    chdir $d or die "Can't chdir $d: $!\n";

    my $module = $d =~ s|.*/||r;
    say "Checking coverage of $module";
    my $output = "**** Checking coverage of $module ****\n";

    my $db = "$d/cover_db";
    if (-d $db) {
        $output .= "Already analysed\n";
        return unless $self->force;
    }

    $output .= "Testing $module\n";
    # TODO - is ths needed?
    $output .= $self->sys($^X, "Makefile.PL") unless -e "Makefile";

    eval {
        local $SIG{ALRM} = sub { die "alarm\n" };
        alarm $self->timeout;
        $ENV{DEVEL_COVER_TEST_OPTS} = "-Mblib=" . $self->bin_dir;
        my @cmd = ($^X, $ENV{DEVEL_COVER_TEST_OPTS}, $self->bin_dir . "/cover");
        $output .= $self->sys(
            @cmd,          "-test",
            "-report",     $self->report,
            "-outputfile", $self->outputfile,
        );
        $output .= $self->sys(@cmd, "-report", "json", "-nosummary");
        alarm 0;
    };
    if ($@) {
        die unless $@ eq "alarm\n";   # propagate unexpected errors
        warn "$output\nTimed out after " . $self->timeout . " seconds!\n";
    }

    my $dir = $self->results_dir // die "No results dir";
    $output .= $self->sys("mkdir", "-p", $dir);
    $dir .= "/$module";
    # TODO - option to merge DB with existing one
    # TODO - portability
    $output .= $self->sys("rm", "-rf", $dir);
    $output .= $self->sys("mv", $db, $dir);
    $output .= $self->sys("rm", "-rf", $db);

    my $line = "=" x 80;
    say "\n$line\n$output$line\n";
}

sub run_all {
    my $self = shift;

    my @res = iterate_as_array
    (
        { workers => $self->workers },
        sub {
            my (undef, $dir) = @_;
            $self->_set_build_dir($dir);
            eval { $self->run };
            warn "\n\n\n[$dir]: $@\n\n\n" if $@;
        },
        $self->build_dirs
    );
    # print Dumper \@res;
}

sub class
{
    my ($pc) = @_;
    $pc eq "n/a" ? "na" :
    $pc <    75  ? "c0" :
    $pc <    90  ? "c1" :
    $pc <   100  ? "c2" :
                   "c3"
}

sub generate_html {
    my $self = shift;

    my $d = $self->results_dir;
    chdir $d or die "Can't chdir $d: $!\n";

    my $f = "$d/index.html";
    say "\n\nWriting collection output to $f ...";

    my $vars = {
        title    => "Coverage report",
        modules  => [],
        vals     => {},
        headers  => [ grep !/path|time/,
                           @Devel::Cover::DB::Criteria_short, "total" ],
        criteria => [ grep !/path|time/,
                           @Devel::Cover::DB::Criteria,       "total" ],
    };
    # print Dumper $vars, $results;

    opendir my $dh, $d or die "Can't opendir $d: $!";
    my @modules = sort grep !/^\./, readdir $dh;
    closedir $dh or die "Can't closedir $d: $!";

    for my $module (@modules) {
        my $file = "$d/$module/cover.json";
        next unless -e $file;
        say "Adding $module";

        my $io = Devel::Cover::DB::IO::JSON->new;
        my $json = $io->read($file);

        push @{$vars->{modules}}, $module;
        my $m = $vars->{vals}{$module} = {};
        $m->{link} = "$module/index.html";

        for my $criterion (@{$vars->{criteria}}) {
            my $summary = $json->{summary}{Total}{$criterion};
            # print "summary:", Dumper $summary;
            my $pc = $summary->{percentage};
            $pc = defined $pc ? sprintf "%6.2f", $pc : "n/a";
            $m->{$criterion}{pc}      = $pc;
            $m->{$criterion}{class}   = class($pc);
            $m->{$criterion}{details} =
              ($summary->{covered} || 0) . " / " . ($summary->{total} || 0);
        }
    }
    # print "vars ", Dumper $vars;

    $self->write_stylesheet;
    my $template = Template->new({
        LOAD_TEMPLATES => [
            Devel::Cover::Collection::Template::Provider->new({}),
        ],
    });
    $template->process("summary", $vars, $f) or die $template->error;

    say "\n\nWrote collection output to $f";
}


sub cover_modules {
    my $self = shift;

    $self->empty_cpanm_dir;
    $self->build_modules;
    $self->add_build_dirs;
    $self->run_all;
    $self->generate_html;
}

sub write_stylesheet {
    my $self = shift;

    my $css = $self->results_dir . "/collection.css";
    open my $fh, ">", $css or die "Can't open $css: $!\n";
    print $fh <<EOF;
/* Stylesheet for Devel::Cover collection reports */

/* You may modify this file to alter the appearance of your coverage
 * reports. If you do, you should probably flag it read-only to prevent
 * future runs from overwriting it.
 */

/* Note: default values use the color-safe web palette. */

body {
    font-family: sans-serif;
}

h1 {
    text-align : center;
    background-color: #cc99ff;
    border: solid 1px #999999;
    padding: 0.2em;
    -moz-border-radius: 10px;
}

a {
    color: #000000;
}
a:visited {
    color: #333333;
}

table {
    border-spacing: 0px;
}
tr {
    text-align : center;
    vertical-align: top;
}
th,.h,.hh {
    background-color: #cccccc;
    border: solid 1px #333333;
    padding: 0em 0.2em;
    width: 2.5em;
    -moz-border-radius: 4px;
}
.hh {
    width: 25%;
}
td {
    border: solid 1px #cccccc;
    border-top: none;
    border-left: none;
    -moz-border-radius: 4px;
}
.hblank {
    height: 0.5em;
}
.dblank {
    border: none;
}

/* source code */
pre,.s {
    text-align: left;
    font-family: monospace;
    white-space: pre;
    padding: 0.2em 0.5em 0em 0.5em;
}

/* Classes for color-coding coverage information:
 *   c0  : path not covered or coverage < 75%
 *   c1  : coverage >= 75%
 *   c2  : coverage >= 90%
 *   c3  : path covered or coverage = 100%
 */
.c0 {
    background-color: #ff9999;
    border: solid 1px #cc0000;
}
.c1 {
    background-color: #ffcc99;
    border: solid 1px #ff9933;
}
.c2 {
    background-color: #ffff99;
    border: solid 1px #cccc66;
}
.c3 {
    background-color: #99ff99;
    border: solid 1px #009900;
}
EOF

    close $fh or die "Can't close $css: $!\n";
}

package Devel::Cover::Collection::Template::Provider;

use strict;
use warnings;

# VERSION

use base "Template::Provider";

my %Templates;

sub fetch
{
    my $self = shift;
    my ($name) = @_;
    # print "Looking for <$name>\n";
    $self->SUPER::fetch(exists $Templates{$name} ? \$Templates{$name} : $name)
}

$Templates{colours} = <<'EOT';
[%
    colours = {
        default => "#ffffad",
        text    => "#000000",
        number  => "#ffffc0",
        error   => "#ff0000",
        ok      => "#00ff00",
    }
%]

[% MACRO bg BLOCK -%]
bgcolor="[% colours.$colour %]"
[%- END %]
EOT

$Templates{html} = <<'EOT';
<!DOCTYPE html
     PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN"
     "http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd">
<html xmlns="http://www.w3.org/1999/xhtml">
<!--
This file was generated by Devel::Cover Version $VERSION
Devel::Cover is copyright 2001-2014, Paul Johnson (paul\@pjcj.net)
Devel::Cover is free. It is licensed under the same terms as Perl itself.
The latest version of Devel::Cover should be available from my homepage:
http://www.pjcj.net
-->
[% PROCESS colours %]
<head>
    <meta http-equiv="Content-Type" content="text/html; charset=utf-8"></meta>
    <meta http-equiv="Content-Language" content="en-us"></meta>
    <link rel="stylesheet" type="text/css" href="collection.css"></link>
    <title> [% title %] </title>
</head>
<body>
    [% content %]
</body>
</html>
EOT

$Templates{summary} = <<'EOT';
[% WRAPPER html %]

<h1> [% title %] </h1>

<table>

    [% IF modules %]
        <tr align="right" valign="middle">
            <th class="header" align="left"> File </th>
            [% FOREACH header = headers %]
                <th class="header"> [% header %] </th>
            [% END %]
        </tr>
    [% END %]

    [% FOREACH module = modules %]
        <tr align="right" valign="middle">
            <td align="left">
                <a href="[%- vals.$module.link -%]"> [% module %] </a>
            </td>

            [% FOREACH criterion = criteria %]
                <td class="[%- vals.$module.$criterion.class -%]"
                    title="[%- vals.$module.$criterion.details -%]">
                    [% vals.$module.$criterion.pc %]
                </td>
            [% END %]
        </tr>
    [% END %]

</table>

<br/>

<hr/>
Coverage information from <a href="https://metacpan.org/module/Devel::Cover">
  Devel::Cover
</a> by <a href="http://pjcj.net">Paul Johnson</a>.

<br/>

<a href="http://cpancover.com/blead/latest/coverage.html">Core coverage</a>
(under development)

<br/>
<br/>

This server generously donated by
<a href="http://www.bytemark.co.uk/r/cpancover">
  <img src="http://www.bytemark.co.uk/images/subpages/spreadtheword/bytemark_logo_179_x_14.png" alt="bytemark"/>
</a>

[% END %]
EOT

"
We have normality, I repeat we have normality.
Anything you still can’t cope with is therefore your own problem.
"

__END__

=head1 NAME

Devel::Cover::Collection - Code coverage for a collection of modules

=head1 SYNOPSIS

=head1 DESCRIPTION

=head1 OPTIONS

=head1 ENVIRONMENT

=head1 BUGS

Almost certainly.

=head1 LICENCE

Copyright 2014, Paul Johnson (paul@pjcj.net)

This software is free.  It is licensed under the same terms as Perl itself.

The latest version of this software should be available on CPAN and from my
homepage: http://www.pjcj.net/.

=cut
