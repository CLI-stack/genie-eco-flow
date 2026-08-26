#!/usr/bin/perl

use strict;
use warnings;


my $dir_path = $ARGV[0];

if (not $dir_path) {
    die "Error: No directory path provided on the command line.\n" .
        "Usage: $0 /path/to/main/directory\n";
}

if (not -d $dir_path) {
    die "Error: '$dir_path' is not a valid directory. Exiting.\n";
}

#print "Input directory: $dir_path\n";
my $report_file = "$dir_path/rpts/FxSynthesize/block_area.rpt.gz";

if (not -f $report_file) {
    die "Error: Constructed file path '$report_file' is not a valid file. Exiting.\n";
}
if (not -r $report_file) {
    die "Error: Constructed file path '$report_file' is not readable (check permissions). Exiting.\n";
}

#print "Attempting to read file: $report_file\n\n";

open(my $fh, "-|", "gzip -dc $report_file")
    or die "Error: Cannot open or decompress gzipped file '$report_file': $!\n";

print "#table#\n";
print "BlockName,StdArea,MemoryArea\n";

while (my $line = <$fh>) {
    chomp($line); 
    if ($line =~ /^BlockArea:\s+/) {
        my @columns = split(/\s+/, $line);

        # Idx: 0         1         2          3         4             5          6
        # Hdr: #BlockArea: BlockName TotalArea  StdArea   StdcellCount  MemoryArea MacroArea
        # Data: BlockArea: bpm_sdma  37.42128   37.42128  658           0          0
        
        if (scalar(@columns) >= 6) {
            my $block_name = $columns[1];
            my $std_area   = $columns[3];
            my $mem_area   = $columns[5];

            print "$block_name,$std_area,$mem_area\n";
            
        }
        
    }
}
print "#table end#\n";

close($fh);

#print "\nExtraction complete.\n";

exit 0;
