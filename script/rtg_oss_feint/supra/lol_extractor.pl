#!/usr/bin/perl

use strict;
use warnings;
use File::Find;      # For recursive directory searching
use File::Spec;      # For building file paths correctly
use File::Basename 'basename';
use Cwd 'abs_path';  # For resolving absolute paths

# --- 1. Get and Validate Input ---

my $input_path = $ARGV[0];
my $logfile = 'lol_log.rpt';
my $result = 'lol.csv';


open(my $log, '>', $logfile) or die "Could not open file '$logfile' for writing: $!";
open(my $res, '>', $result) or die "Could not open file '$logfile' for writing: $!";

# Check if an argument was provided
unless (defined $input_path) {
    die "Usage: $0 <path_to_report | path_to_tile_dir | tile_dir_name>\n";
}

# Remove a trailing slash if it exists, for consistency
$input_path =~ s{/$}{};

my $base_dir; # This will store the final .../tiles/osssys_1011 path

# --- 2. Determine the Base Directory ---

# Case 1: Input is the full report file path
if (-f $input_path && $input_path =~ /\.flop2flop\.alol\.summary\.rpt$/) {
    print $log "Info: Full report path provided.\n";
    
    # Extract the TILE_NAME from the filename itself
    my $report_basename = basename($input_path);
    my ($extracted_tile_name) = ($report_basename =~ /^(.*?)\.flop2flop\.alol\.summary\.rpt$/);

    if ($extracted_tile_name) {
        print $log "Info: Extracted TILE_NAME '$extracted_tile_name' from filename.\n";
        
        # Call the sub and capture its return values
        my @results = process_report($input_path, $extracted_tile_name);

        # Only print if @results is NOT empty
        if (@results) {
            print "--- LOL $extracted_tile_name ( >= 27 ) ---\n";
            print $log "$results[0]\n"; # Print the header string
            print $log "$results[1]\n"; # Print the data string
            print "----------------------------------------\n";
        }
    } else {
        warn "Warning: Could not extract TILE_NAME from report filename '$report_basename'. Cannot process file.";
    }
    exit 0; # Done
}

# Case 2: Input is a direct, valid directory path (e.g., /proj/.../osssys_1011 or ./osssys_1011)
elsif (-d $input_path) {
    print $log "Info: Input is a valid directory. Using as base.\n";
    $base_dir = abs_path($input_path); 
}

# Case 3: Input is just a name (e.g., osssys_1011). Search for it.
else {
    print $log "Info: Input '$input_path' is not a direct path. Searching current directory tree...\n";
    my $found_path;

    find(
        sub {
            return if $found_path;
            if ($_ eq $input_path && -d $File::Find::name) {
                $found_path = $File::Find::name;
                $File::Find::prune = 1; 
            }
        },
        '.' # Start from current working directory
    );

    if ($found_path) {
        $base_dir = abs_path($found_path); 
        print $log "Info: Found directory at: $base_dir\n"; 
    } else {
        die  "Error: Could not find directory named '$input_path' starting from the current location.\n";
    }
}

# --- 3. Process the Found Base Directory (Cases 2 & 3) ---

print $log "Info: Processing tile directory: $base_dir\n";

# --- 4. Find and Parse tile.params ---

my $tile_params_file = File::Spec->catfile($base_dir, 'tile.params');

unless (-r $tile_params_file) {
    die "Error: Cannot find or read 'tile.params' at: $tile_params_file\n";
}

my $tile_name;
open(my $fh_params, '<', $tile_params_file)
    or die "Error: Could not open '$tile_params_file': $!\n";

while (my $line = <$fh_params>) {
    chomp $line;
    if ($line =~ /^\s*TILE_NAME\s*=\s*(\S+)/) {
        $tile_name = $1;
        last; 
    }
}
close $fh_params;

unless (defined $tile_name) {
    die "Error: Could not find 'TILE_NAME' variable in '$tile_params_file'.\n";
}

print $log "Info: Found TILE_NAME = $tile_name\n";

# --- 5. Define Target File and Search Directory ---

my $target_filename = "${tile_name}.flop2flop.alol.summary.rpt";

# Auto-detect synthesize target: FxSynthesize (UMC) or FxPixSynthesize (OSS)
my $search_dir;
my $rpts_dir = File::Spec->catfile($base_dir, 'rpts');
if (-d File::Spec->catfile($rpts_dir, 'FxSynthesize')) {
    $search_dir = File::Spec->catfile($rpts_dir, 'FxSynthesize');
} elsif (-d File::Spec->catfile($rpts_dir, 'FxPixSynthesize')) {
    $search_dir = File::Spec->catfile($rpts_dir, 'FxPixSynthesize');
} else {
    # Neither exists - print warning and exit gracefully
    print $log "Warning: No synthesize report directory found (FxSynthesize or FxPixSynthesize)\n";
    print "#text#\n";
    print "LOL report not available - no synthesize target directory found\n";
    exit 0;
}

print $log "Info: Using synthesize target directory: $search_dir\n";

print $log "Info: Searching for '$target_filename' in '$search_dir'...\n";

# --- 6. Recursively Search for the Report ---

my $found_flag = 0;

find(
    sub {
        if ($_ eq $target_filename && -f $File::Find::name) {
            # Call the sub and capture its return values
            my @results = process_report($File::Find::name, $tile_name);
            
            # Only print if @results is NOT empty
            if (@results) {
                print "#text#\n" ;
                print " Directory path: $File::Find::name\n";
                #print "--- Processing $tile_name ( >= 27 ) ---\n";
                print "#table#\n";
                print  "$results[0]\n"; # Print the header string
                print $res "$results[0]\n"; # Print the header string

                print "$results[1]\n"; # Print the data string
                print $res "$results[1]\n"; # Print the header string
                print "#table end#\n";
                print "----------------------------------------\n";
            }
            
            $found_flag = 1;
        }
    },
    $search_dir
);

# --- 7. Final Report ---

if (!$found_flag) {
    print $log "Warning: Did not find '$target_filename' anywhere under '$search_dir'.\n";
}

exit 0;


# --- 8. Subroutine Definition ---

# SUBROUTINE to process the found report file
#
sub process_report {
    my ($report_file, $tile_name) = @_;

    my $header_line = "";
    my $data_line = "";

    open(my $fh, '<', $report_file) 
        or do { warn "Error: Could not open '$report_file': $!"; return; };

    # Read the report file to find the two specific lines
    while (my $line = <$fh>) {
        if ($line =~ /^\s*flop2flop\b/) {
            $header_line = $line;
        }
        elsif ($line =~ /^\s*$tile_name\b/) {
            $data_line = $line;
        }
        last if $header_line && $data_line;
    }
    close $fh;

    # --- Parse the extracted lines ---
    
    unless ($header_line && $data_line) {
        warn "Warning: Could not find 'flop2flop' or '$tile_name' data in '$report_file'.";
        return;
    }

    chomp $header_line;
    chomp $data_line;

    my @headers = split /\s+/, $header_line;
    my @data    = split /\s+/, $data_line;

    if (scalar(@headers) != scalar(@data)) {
        warn "Warning: Data mismatch. Header and data lines have different column counts in '$report_file'.";
        return;
    }

    # --- Filter data based on header >= 27 ---
    
    my @csv_headers;
    my @csv_data;

    push @csv_headers, $headers[0]; # Add text header (flop2flop)
    push @csv_data, $data[0];       # Add text data (tile_name)

    for (my $i = 1; $i < scalar(@headers); $i++) {
        my $value = $headers[$i];
        
        next unless $value =~ /^\d+$/; 

        if ($value >= 27) {
            push @csv_headers, $value;
            push @csv_data, $data[$i];
        }
    }

    # --- FINAL CHECK: Skip if all filtered data values are zero ---
    
    my $all_zeros = 1;
    # Start checking from index 1, as index 0 is the TILE_NAME string
    for (my $i = 1; $i < scalar(@csv_data); $i++) {
        if ($csv_data[$i] != 0) {
            $all_zeros = 0;
            last; # Found a non-zero value, exit loop
        }
    }

    if ($all_zeros) {
        # Data is all zeros, return an empty list
        return ();
        
    } else {
        # Return the two CSV strings as a list
        return (
            join(",", @csv_headers),
            join(",", @csv_data)
        );
    }
}
close ($log);
close ($res);

