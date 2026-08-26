#!/usr/bin/perl
# Extract runtime information from TileBuilder task log files
# Usage: perl extract_task_runtime.pl <status_log> <logs_dir> [target_name]
# Outputs CSV: TaskID,Target,Status,Runtime

use strict;
use warnings;

my $status_log = $ARGV[0] || die "Usage: $0 <status_log> <logs_dir> [target_name]\n";
my $logs_dir = $ARGV[1] || die "Usage: $0 <status_log> <logs_dir> [target_name]\n";
my $target_filter = $ARGV[2] || "";

# Read status log
open(my $fh, '<', $status_log) or die "Cannot open $status_log: $!\n";

while (my $line = <$fh>) {
    chomp $line;
    next if $line =~ /^\s*$/;
    
    my ($task_id, $task_name, $task_status) = split(/\s+/, $line);
    
    # Filter by target if specified
    if ($target_filter ne "" && $task_name ne $target_filter) {
        next;
    }
    
    # Extract runtime from log file
    my $runtime = "N/A";
    my $log_file = "$logs_dir/${task_name}.log.gz";
    
    if (-f $log_file) {
        my $elapsed_line = `zcat $log_file | grep "Elapsed time for this session"`;
        if ($elapsed_line =~ /(\d+)\s+seconds/) {
            $runtime = $1;
        }
    }
    
    # Print only runtime (no header, no other fields)
    print "$runtime\n";
}

close($fh);
