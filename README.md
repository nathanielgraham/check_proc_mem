# NAME
check_proc_mem.pl

## SYNOPSIS 
check_proc_mem.pl -P <proc_name> 

## DESCRIPTION
Nagios plugin to calculate the total resident set size (Rss) used by the supplied process name and all other processes sharing the same pgid (process group id). Rss is the amount of shared memory plus unshared memory used by a process.

## USAGE 
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

## CAVEATS
You're probably trying to calculate the actual memory used by an application or process. There is no easy way to calculate this, but Rss gives you a rough idea. The problems are:

1. Multiple processes can share the same pages. You can add up the RSS of all running processes, and end up with much more than the physical memory of your machine.

2. Private pages belonging to the process can be swapped out, or might not be initialised yet.


