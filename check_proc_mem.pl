#!/usr/bin/env perl

use strict;
use warnings;
use feature qw(say);
use Getopt::Long qw(:config no_ignore_case);

use constant VERSION => '0.02';

# page size in bytes
my $pagesize = `getconf PAGESIZE`;
chomp $pagesize;
return_status( { return_code => 3, error => "unknown pagesize" } )
  unless $pagesize && $pagesize =~ /^\d+$/;

sub help {
    return <<EOT;
Usage:
check_proc_mem.pl -P <proc_name> -w <wrta> -c <crta>

Options:
 -h, --help
    Print detailed help screen
 -v, --verbose
    verbose output
 -V, --version
    plugin version
 -w, --warning=THRESHOLD
    warning threshold in kB
 -c, --critical=THRESHOLD
    critical threshold in kB
 -P, --proc-name=PROCESS_NAME
    process name (e.g. httpd, nginx)
 -t, --timeout=NUMBER
    timeout in seconds (default 10)
 -u
    unit of mesure (e.g. kB, mB, MB)
EOT
}

# options
my $o_unit = 'KB';
my ( $o_help, $o_warning, $o_critical, $o_timeout, $o_verbose, @o_proc_name );

GetOptions(
    "version" => sub { say VERSION; exit 0 },
    "V"       => sub { say VERSION; exit 0 },
    "help"    => sub { say help();  exit 0 },
    "h"       => sub { say help();  exit 0 },
    "timeout=i"   => \$o_timeout,
    "t=i"         => \$o_timeout,
    "warning=s"   => \$o_warning,
    "w=s"         => \$o_warning,
    "critical=s"  => \$o_critical,
    "c=s"         => \$o_critical,
    "verbose"     => \$o_verbose,
    "v"           => \$o_verbose,
    "u=s"         => \$o_unit,
    "proc-name=s" => \@o_proc_name,
    "P=s"         => \@o_proc_name,
);

# required params
return_status( { return_code => 3, error => "proc-name required" } )
  unless @o_proc_name;

# allow comma delimited list of procs
@o_proc_name = split( /\s*,\s*/, join( ',', @o_proc_name ) );

# unit of measure multiplier
# debatable: kB and KB both mean 1024 bytes in the linux world
my %uom = (
    'B'   => 1,
    'KB'  => 1 / 1024,
    'KIB' => 1 / 1024,
    'MB'  => 1 / ( 1024 * 1024 ),
    'MIB' => 1 / ( 1024 * 1024 ),
    'GB'  => 1 / ( 1024 * 1024 * 1024 ),
    'GIB' => 1 / ( 1024 * 1024 * 1024 ),
    'TB'  => 1 / ( 1024 * 1024 * 1024 * 1024 ),
    'TIB' => 1 / ( 1024 * 1024 * 1024 * 1024 )
);

return_status(
    { return_code => 3, error => "unknown unit of measure: $o_unit" } )
  unless exists $uom{ uc($o_unit) };

# handle sig alarm
$SIG{'ALRM'} = sub {
    return_status( { return_code => 3, error => "Alarm time out" } );
};

# set alarm
$o_timeout = 10 unless defined $o_timeout;
say("Alarm at $o_timeout") if $o_verbose;
alarm($o_timeout);

# build pid pgrp proc data structures
my ( %pid, %pgrp, %proc );
opendir( DIR, "/proc" )
  or return_status( { return_code => 3, error => 'unable to read /proc' } );
while ( my $file = readdir(DIR) ) {
    next unless $file =~ /^\d+$/;
    open( STAT, "/proc/$file/stat" )
      or next;
    while (<STAT>) {
        chomp;
        my @vals = split;
        $vals[1] =~ s/\W+//g;
        my ( $pid, $name, $ppid, $pgrp, $vmsize, $rss ) =
          @vals[ 0, 1, 3, 4, 22, 23 ];
        $pid{$pid} = [ $name, $ppid, $pgrp, $vmsize, $rss ];
        push @{ $pgrp{$pgrp} }, $pid;
        push @{ $proc{$name} }, $pid;
    }
    close(STAT);
}
closedir(DIR);

# find all pgids of all matched processes
my %all_pgids;
for my $proc (@o_proc_name) {
    for my $p ( @{ $proc{$proc} } ) {
        my $pgid = $pid{$p}->[2];
        next unless $pgid;
        $all_pgids{$pgid}++;
    }
}

# add up rss per proc for each pgid
my $rss_grand_total = 0;
my %rss_proc_total;
for my $pgid ( keys %all_pgids ) {
    for my $p1 ( $pgrp{$pgid} ) {
        for my $p2 (@$p1) {
            my $rss  = $pid{$p2}->[4];
            my $name = $pid{$p2}->[0];
            next unless $rss && $name;
            $rss_proc_total{$name} += $rss;
            $rss_grand_total += $rss;
        }
    }
}

# return error if zero pages found
return_status( { return_code => 3, error => "procs not found: @o_proc_name" } )
  unless $rss_grand_total;

# adjust for pagesize and uom
my $rss_total = $rss_grand_total * $pagesize * $uom{ uc($o_unit) };

# warning and critical alerts: 0=pass, 1=alert, 2=malformed, undef=missing
my ( $warn_alert, $crit_alert );
$warn_alert = gen_alert( $o_warning,  $rss_total ) if $o_warning;
$crit_alert = gen_alert( $o_critical, $rss_total ) if $o_critical;

# return error if malformed warning option
return_status( { return_code => 3, error => "malformed warning" } )
  if $warn_alert && $warn_alert == 2;

# return error if malformed critical option
return_status( { return_code => 3, error => "malformed critical" } )
  if $crit_alert && $crit_alert == 2;

# determine return code
my $return_code = $crit_alert ? 2 : $warn_alert ? 1 : 0;

# return and exit
return_status(
    {
        return_code     => $return_code,
        rss_grand_total => $rss_grand_total,
        rss_proc_total  => \%rss_proc_total,
        warning         => $o_warning,
        critical        => $o_critical
    }
);

# 0 = pass, 1 = alert, 2 = malformed
sub gen_alert {
    my ( $thresh, $val ) = @_;
    my $match = 0;

    if ( $thresh =~ /^(\d+)$/ ) {
        return 1 if ( $val < 0 or $val > $1 );
        $match++;
    }
    elsif ( $thresh =~ /^(\d+):$/ ) {
        return 1 if ( $val < $1 );
        $match++;
    }
    elsif ( $thresh =~ /^~:(\d+)$/ ) {
        return 1 if ( $val > $1 );
        $match++;
    }
    elsif ( $thresh =~ /^(\d+):(\d+)$/ ) {
        return 1 if ( $val < $1 or $val > $2 );
        $match++;
    }
    elsif ( $thresh =~ /^@(\d+):(\d+)$/ ) {
        return 1 if ( $val >= $1 and $val <= $2 );
        $match++;
    }
    return $match ? 0 : 2;
}

sub return_status {
    my $opt_href    = shift;
    my $return_code = $opt_href->{return_code};
    if ( exists $opt_href->{error} ) {
        say( "UNKNOWN ERROR: " . $opt_href->{error} );
        exit $return_code;
    }
    my $grand_total = $opt_href->{rss_grand_total};
    my %proc_total  = %{ $opt_href->{rss_proc_total} };
    my $warning     = $opt_href->{warning};
    my $critical    = $opt_href->{critical};

    # generate return status
    my $return_status =
        $return_code == 0 ? 'OK'
      : $return_code == 1 ? 'WARNING'
      : $return_code == 2 ? 'CRITICAL'
      :                     'UNKNOWN';

    # maximum verbosity
    if ($o_verbose) {
        say "Pagesize: $pagesize";
        while ( my ( $name, $rss ) = each %proc_total ) {
            say "$name Rss pages used: $rss";
        }
        say "Total Rss pages used: $rss_grand_total";
        say( "Total Rss bytes used: " . $rss_grand_total * $pagesize );
        say( "Perf data unit of measure: " . $o_unit );
    }

    # calculate rss size in unit of measure
    my $perf_rss_size = $rss_grand_total * $pagesize * $uom{ uc($o_unit) };

    # multiply by eight if they want bits (lower case b)
    $perf_rss_size *= 8 if substr( $o_unit, -1, 1 ) eq 'b';

    # generate user data
    my $userdata = "check_proc_mem.pl $return_status - $perf_rss_size $o_unit";

    # generate perf data
    my $perfdata;
    while ( my ( $name, $rss ) = each %proc_total ) {
        $perfdata .=
          "$name=" . $rss * $pagesize * $uom{ uc($o_unit) } . $o_unit;
        $perfdata .= ";$warning"  if defined $warning;
        $perfdata .= ";$critical" if defined $critical;
        $perfdata .= " ";
    }
    $perfdata .= "total=$perf_rss_size$o_unit";
    $perfdata .= ";$warning" if defined $warning;
    $perfdata .= ";$critical" if defined $critical;

    # return and exit
    say "$userdata | $perfdata";
    exit $return_code;
}

=head1 NAME

check_proc_map.pl

=head1 SYNOPSIS

check_proc_mem.pl -P <proc_name>

=head1 DESCRIPTION

Calculates the total resident set size (Rss) used by the supplied process name and all other processes sharing same pgid (process group id). Rss is the amount of shared memory plus unshared memory used by a process.

=head1 CAVEATS

You're probably trying to calculate the actual memory used by an application or process. There is no easy way to calculate this, but Rss gives you a rough idea. The problems are:

=over

=item

Multiple processes can share the same pages. You can add up the RSS of all running processes, and end up with much more than the physical memory of your machine.

=item

Private pages belonging to the process can be swapped out. Or they might not be initialised yet.

=back


=cut
