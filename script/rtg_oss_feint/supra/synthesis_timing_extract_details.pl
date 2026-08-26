#!/usr/bin/perl
# Combined synthesis timing and area extraction script
# Extracts WNS/TNS/NVP from FxSynthesize.dat, Vt usage from multi_vt report
# Outputs CSV to stdout
# Usage: perl script.pl <dir1> <date1> [dir2] [date2] ... [--blocks=UCLK,DFICLK,I2C]
#
# If --blocks is not specified, ALL cost groups found in the .dat file are extracted
# Additionally extracts: UCLK_WNS, UCLK_TNS, UCLK_NVP (calculated from r2r groups)
#                       ULVTLL_Count%, ULVTLL_Area% (from multi_vt report)

use strict;
use warnings;

# ============================================================================
# Parse Command Line Arguments
# ============================================================================
my @block_args = grep { /^--blocks=/ } @ARGV;
@ARGV = grep { !/^--blocks=/ } @ARGV;

die "ERROR: Directory/date pairs required\n" unless @ARGV >= 2 && @ARGV % 2 == 0;

# If --blocks specified, use those; otherwise auto-detect later
my @cost_groups;
my $auto_detect_blocks = 1;

if (@block_args) {
    my ($block_str) = $block_args[0] =~ /^--blocks=(.*)/;
    @cost_groups = split(/,/, $block_str);
    $auto_detect_blocks = 0;
}

# ============================================================================
# Process Each Directory (First Pass: collect data and auto-detect cost groups)
# ============================================================================
my @csv_rows;
my @dir_pairs;
my %all_cost_groups;  # Track all discovered cost groups across directories

# Collect directory pairs
while (@ARGV) {
    my $dir = shift @ARGV;
    my $date = shift @ARGV;
    push @dir_pairs, [$dir, $date];
}

# First pass: parse all directories and collect cost groups
my @parsed_data;
foreach my $pair (@dir_pairs) {
    my ($dir, $date) = @$pair;

    # Extract changelist number from override.params (SYN_VF_FILE)
    my $changelist = extract_changelist_from_params("$dir/override.params");

    # Parse FxSynthesize.dat for timing and area
    my %timing_data = parse_synthesis_dat("$dir/rpts/FxSynthesize/FxSynthesize.dat");
    my ($std_area, $ram_area) = parse_area_from_dat("$dir/rpts/FxSynthesize/FxSynthesize.dat");

    # Parse multi_vt report for Vt cell usage
    my %vt_data = parse_multi_vt_report("$dir/rpts/FxSynthesize/multi_vt.pass_3.rpt.gz");

    # Calculate Design metrics (from r2r groups)
    my ($design_wns, $design_tns, $design_nvp) = calculate_design_metrics(\%timing_data);

    # If auto-detecting, collect all cost groups found
    if ($auto_detect_blocks) {
        foreach my $group (keys %timing_data) {
            $all_cost_groups{$group} = 1;
        }
    }

    push @parsed_data, {
        date => $date,
        changelist => $changelist,
        std_area => $std_area,
        ram_area => $ram_area,
        timing => \%timing_data,
        vt => \%vt_data,
        design_wns => $design_wns,
        design_tns => $design_tns,
        design_nvp => $design_nvp
    };
}

# If auto-detecting, set cost_groups from discovered groups (sorted alphabetically)
if ($auto_detect_blocks) {
    @cost_groups = sort keys %all_cost_groups;
}

# ============================================================================
# Initialize CSV Headers (after cost groups are known)
# ============================================================================
my @csv_headers = ('Date', 'CL', 'StdCellArea', 'RamArea',
                   'Design_WNS', 'Design_TNS', 'Design_NVP',
                   'ULVTLL_Count%', 'ULVTLL_Area%', 'TotalCells');

# Add headers for each cost group (timing: WNS, TNS, NVP)
foreach my $group (@cost_groups) {
    push @csv_headers, "${group}_WNS", "${group}_TNS", "${group}_NVP";
}

# ============================================================================
# Build CSV Rows
# ============================================================================
foreach my $data (@parsed_data) {
    my @row_data = (
        $data->{date},
        $data->{changelist},
        $data->{std_area},
        $data->{ram_area},
        $data->{design_wns},
        $data->{design_tns},
        $data->{design_nvp},
        $data->{vt}{ulvtll_count_pct} // 'N/A',
        $data->{vt}{ulvtll_area_pct} // 'N/A',
        $data->{vt}{total_cells} // 'N/A'
    );

    foreach my $group (@cost_groups) {
        my $wns = $data->{timing}{$group}{wns} // 'N/A';
        my $tns = $data->{timing}{$group}{tns} // 'N/A';
        my $nvp = $data->{timing}{$group}{nvp} // 'N/A';
        push @row_data, $wns, $tns, $nvp;
    }

    push @csv_rows, \@row_data;
}

# ============================================================================
# Output Detailed Report
# ============================================================================
foreach my $i (0 .. $#parsed_data) {
    my $data = $parsed_data[$i];
    my ($dir, $date) = @{$dir_pairs[$i]};
    my $changelist = $data->{changelist} // 'N/A';

    # --- Run Info ---
    print "#text#\n";
    print "Run: $dir\n";
    print "Changelist: $changelist\n";

    # --- Summary Metrics Table ---
    print "#title#\n";
    print "Summary Metrics\n";
    print "#table#\n";
    print "Metric,Value\n";
    print "Design_WNS,$data->{design_wns} ps\n";
    print "Design_TNS,$data->{design_tns} ps\n";
    print "Design_NVP,$data->{design_nvp}\n";
    print "StdCell_Area,$data->{std_area}\n";
    print "RAM_Area,$data->{ram_area}\n";
    my $ulvtll_count = $data->{vt}{ulvtll_count_pct} // 'N/A';
    my $ulvtll_area = $data->{vt}{ulvtll_area_pct} // 'N/A';
    my $total_cells = $data->{vt}{total_cells} // 'N/A';
    print "ULVTLL_Count%,${ulvtll_count}%\n" if $ulvtll_count ne 'N/A';
    print "ULVTLL_Count%,$ulvtll_count\n" if $ulvtll_count eq 'N/A';
    print "ULVTLL_Area%,${ulvtll_area}%\n" if $ulvtll_area ne 'N/A';
    print "ULVTLL_Area%,$ulvtll_area\n" if $ulvtll_area eq 'N/A';
    print "TotalCells,$total_cells\n";
    print "#table end#\n";

    # --- Get Primary and Other Groups using auto-detection ---
    my ($primary_groups_ref, $other_groups_ref) = get_primary_timing_groups($data->{timing});

    # --- Primary Timing Groups Table ---
    print "\n#title#\n";
    print "Primary Timing Groups\n";
    print "#table#\n";
    print "PathGroup,WNS,TNS,NVP\n";

    foreach my $g (@$primary_groups_ref) {
        print "$g->{name},$g->{wns},$g->{tns},$g->{nvp}\n";
    }
    print "#table end#\n";

    # --- Other Path Groups Table ---
    print "\n#title#\n";
    print "Other Path Groups\n";
    print "#table#\n";
    print "PathGroup,WNS,TNS,NVP\n";

    foreach my $g (@$other_groups_ref) {
        print "$g->{name},$g->{wns},$g->{tns},$g->{nvp}\n";
    }
    print "#table end#\n";

    # --- Vt Cell Usage Table ---
    print "\n#title#\n";
    print "Vt Cell Usage\n";
    print "#table#\n";
    print "Vt_Group,Cell_Count,Count%,Area,Area%\n";

    # Define display order for Vt groups (most aggressive first)
    my @vt_order = ('UltraLow_Vt_LL', 'UltraLow_Vt', 'Low_Vt_LL', 'Low_Vt', 'undefined');

    my $vt_total_cells = $data->{vt}{total_cells} // 'N/A';
    my $vt_total_area = $data->{vt}{total_area} // 'N/A';

    foreach my $vt_group (@vt_order) {
        if (exists $data->{vt}{groups}{$vt_group}) {
            my $g = $data->{vt}{groups}{$vt_group};
            my $count = $g->{count} // 'N/A';
            my $count_pct = $g->{count_pct} // 'N/A';
            my $area = $g->{area} // 'N/A';
            my $area_pct = $g->{area_pct} // 'N/A';
            $count_pct = "${count_pct}%" if $count_pct ne 'N/A';
            $area_pct = "${area_pct}%" if $area_pct ne 'N/A';
            print "$vt_group,$count,$count_pct,$area,$area_pct\n";
        }
    }

    # Print Total row
    print "Total,$vt_total_cells,100%,$vt_total_area,100%\n";
    print "#table end#\n";
}

# ============================================================================
# Output Pass Progression Table (only if pass files exist)
# ============================================================================
foreach my $pair (@dir_pairs) {
    my ($dir, $date) = @$pair;

    # Check if pass files exist (pass_1, pass_2, pass_3)
    my $has_pass_files = (-e "$dir/rpts/FxSynthesize/FxSynthesize.pass_1.proc_qor.rpt.gz" &&
                          -e "$dir/rpts/FxSynthesize/FxSynthesize.pass_2.proc_qor.rpt.gz" &&
                          -e "$dir/rpts/FxSynthesize/FxSynthesize.pass_3.proc_qor.rpt.gz");

    # Skip if no pass files found
    unless ($has_pass_files) {
        next;
    }

    # Parse pass progression data
    my %pass_data = parse_pass_progression($dir);

    # Only output if we have pass data
    if (%pass_data && exists $pass_data{1}) {
        print "\n#title#\n";
        print "Pass Progression\n";
        print "#table#\n";
        print "Metric,Pass_1,Pass_2,Pass_3\n";

        # Design WNS row
        my $wns1 = $pass_data{1}{design_wns} // 'N/A';
        my $wns2 = $pass_data{2}{design_wns} // 'N/A';
        my $wns3 = $pass_data{3}{design_wns} // 'N/A';
        print "Design_WNS,$wns1,$wns2,$wns3\n";

        # TNS row
        my $tns1 = $pass_data{1}{tns} // 'N/A';
        my $tns2 = $pass_data{2}{tns} // 'N/A';
        my $tns3 = $pass_data{3}{tns} // 'N/A';
        print "TNS,$tns1,$tns2,$tns3\n";

        # NVP row
        my $nvp1 = $pass_data{1}{nvp} // 'N/A';
        my $nvp2 = $pass_data{2}{nvp} // 'N/A';
        my $nvp3 = $pass_data{3}{nvp} // 'N/A';
        print "NVP,$nvp1,$nvp2,$nvp3\n";

        # ULVTLL % row
        my $ulvtll1 = $pass_data{1}{ulvtll_pct} // 'N/A';
        my $ulvtll2 = $pass_data{2}{ulvtll_pct} // 'N/A';
        my $ulvtll3 = $pass_data{3}{ulvtll_pct} // 'N/A';
        $ulvtll1 = "${ulvtll1}%" if $ulvtll1 ne 'N/A';
        $ulvtll2 = "${ulvtll2}%" if $ulvtll2 ne 'N/A';
        $ulvtll3 = "${ulvtll3}%" if $ulvtll3 ne 'N/A';
        print "ULVTLL%,$ulvtll1,$ulvtll2,$ulvtll3\n";

        # Total Cells row
        my $cells1 = $pass_data{1}{total_cells} // 'N/A';
        my $cells2 = $pass_data{2}{total_cells} // 'N/A';
        my $cells3 = $pass_data{3}{total_cells} // 'N/A';
        print "TotalCells,$cells1,$cells2,$cells3\n";

        print "#table end#\n";
    }
}

# ============================================================================
# Subroutine: Extract Changelist from override.params
# ============================================================================
sub extract_changelist_from_params {
    my ($params_file) = @_;

    return 'N/A' unless -e $params_file;

    open(my $fh, '<', $params_file) or return 'N/A';

    my $syn_vf_path = '';

    while (my $line = <$fh>) {
        if ($line =~ /^SYN_VF_FILE\s*=\s*(.*)/) {
            $syn_vf_path = $1;
            last;
        }
    }
    close($fh);

    # Extract base path from SYN_VF_FILE
    my $base_path = '';
    if ($syn_vf_path =~ m{^(/proj/[^/]+/[^/]+/[^/]+)}) {
        $base_path = $1;
    } else {
        return 'N/A';
    }

    # Read configuration_id from base path
    my $config_file = "$base_path/configuration_id";
    return 'N/A' unless -e $config_file;

    open(my $cfh, '<', $config_file) or return 'N/A';
    while (my $line = <$cfh>) {
        if ($line =~ /\@(\d+)/) {
            close($cfh);
            return $1;
        }
    }
    close($cfh);

    return 'N/A';
}

# ============================================================================
# Subroutine: Parse FxSynthesize.dat for Timing (WNS, TNS, NVP)
# ============================================================================
sub parse_synthesis_dat {
    my ($dat_file) = @_;

    my %timing_data;

    return %timing_data unless -e $dat_file;

    open(my $fh, '<', $dat_file) or return %timing_data;

    while (my $line = <$fh>) {
        # Parse CostGroup lines
        # Format: CostGroup: UCLK -117.766 -906319.701 18170 274.6 1.0
        # Fields: name, WNS, TNS, NVP, period, ...
        if ($line =~ /^CostGroup:\s+(\S+)\s+(-?[\d.]+)\s+(-?[\d.]+)\s+(\d+)/) {
            my $group = $1;
            my $wns = $2;
            my $tns = $3;
            my $nvp = $4;

            $timing_data{$group}{wns} = $wns;
            $timing_data{$group}{tns} = $tns;
            $timing_data{$group}{nvp} = $nvp;
        }

        # Parse totalCoreWNS/TNS/NVP lines (primary design metrics)
        # Format: totalCoreWNS: -120.645
        if ($line =~ /^totalCoreWNS:\s+(-?[\d.]+)/) {
            $timing_data{_totalCore}{wns} = $1;
        }
        if ($line =~ /^totalCoreTNS:\s+(-?[\d.]+)/) {
            $timing_data{_totalCore}{tns} = $1;
        }
        if ($line =~ /^totalCoreNVP:\s+(\d+)/) {
            $timing_data{_totalCore}{nvp} = $1;
        }
    }
    close($fh);

    return %timing_data;
}

# ============================================================================
# Subroutine: Parse FxSynthesize.dat for Area
# ============================================================================
sub parse_area_from_dat {
    my ($dat_file) = @_;

    my $std_area = 'N/A';
    my $ram_area = 'N/A';

    return ($std_area, $ram_area) unless -e $dat_file;

    open(my $fh, '<', $dat_file) or return ($std_area, $ram_area);

    while (my $line = <$fh>) {
        # Extract StdCellArea
        if ($line =~ /^StdCellArea:\s+([\d.]+)/) {
            $std_area = sprintf("%.2f", $1);
        }
        # Extract ramArea
        if ($line =~ /^ramArea:\s+([\d.]+)/) {
            $ram_area = sprintf("%.2f", $1);
        }
    }
    close($fh);

    return ($std_area, $ram_area);
}

# ============================================================================
# Subroutine: Parse multi_vt report for Vt cell usage (all Vt groups)
# Fallback to Synthesize.vt_group_details.json if multi_vt doesn't exist
# ============================================================================
sub parse_multi_vt_report {
    my ($vt_file) = @_;

    my %vt_data;

    # Try pass_3 first, then pass_2, then pass_1
    my $actual_file = $vt_file;
    unless (-e $actual_file) {
        $actual_file =~ s/pass_3/pass_2/;
    }
    unless (-e $actual_file) {
        $actual_file =~ s/pass_2/pass_1/;
    }

    # If multi_vt report doesn't exist, try JSON fallback
    unless (-e $actual_file) {
        # Extract base directory from vt_file path
        my $base_dir = $vt_file;
        $base_dir =~ s|/multi_vt\.pass_\d\.rpt\.gz$||;

        my $json_file = "$base_dir/compare_qor_data/data/tables/command_line/command_line/command_line/FxSynthesize/Synthesize.vt_group_details.json";

        if (-e $json_file) {
            return parse_vt_json($json_file);
        }
        return %vt_data;
    }

    open(my $fh, "-|", "gzip -dc $actual_file 2>/dev/null") or return %vt_data;

    my $in_count_section = 0;
    my $in_area_section = 0;

    # Initialize vt_groups array to store all groups
    $vt_data{vt_groups} = [];

    while (my $line = <$fh>) {
        # Detect section headers
        if ($line =~ /^Cell Count Report/) {
            $in_count_section = 1;
            $in_area_section = 0;
            next;
        }
        if ($line =~ /^Cell Area Report/) {
            $in_count_section = 0;
            $in_area_section = 1;
            next;
        }

        # Parse Total line in Cell Count section FIRST (before group parsing)
        # Format: Total                  1625825 (100.00%)    475407  (29.24%)...
        if ($in_count_section && $line =~ /^Total\s+(\d+)\s+\(/) {
            $vt_data{total_cells} = $1;
            next;
        }

        # Parse all Vt group lines in Cell Count section
        # Format: UltraLow_Vt_LL         1199156  (73.76%)    388885  (23.92%)  ...
        # Format: Low_Vt                  252612  (15.54%)     59863   (3.68%)  ...
        if ($in_count_section && $line =~ /^(\w+)\s+(\d+)\s+\(([\d.]+)%\)/) {
            my $group = $1;
            my $count = $2;
            my $pct = $3;

            # Skip header lines and separator lines
            next if $group eq 'Group' || $group eq 'Low';

            $vt_data{groups}{$group}{count} = $count;
            $vt_data{groups}{$group}{count_pct} = $pct;

            # Track ULVTLL specifically for backward compatibility
            if ($group eq 'UltraLow_Vt_LL') {
                $vt_data{ulvtll_count} = $count;
                $vt_data{ulvtll_count_pct} = $pct;
            }
        }

        # Parse Total line in Cell Area section FIRST
        # Format: Total                 95073.58 (100.00%)  15663.04  (16.47%)...
        if ($in_area_section && $line =~ /^Total\s+([\d.]+)\s+\(/) {
            $vt_data{total_area} = $1;
            next;
        }

        # Parse all Vt group lines in Cell Area section
        if ($in_area_section && $line =~ /^(\w+)\s+([\d.]+)\s+\(([\d.]+)%\)/) {
            my $group = $1;
            my $area = $2;
            my $pct = $3;

            next if $group eq 'Group' || $group eq 'Low';

            $vt_data{groups}{$group}{area} = $area;
            $vt_data{groups}{$group}{area_pct} = $pct;

            # Track ULVTLL specifically for backward compatibility
            if ($group eq 'UltraLow_Vt_LL') {
                $vt_data{ulvtll_area} = $area;
                $vt_data{ulvtll_area_pct} = $pct;
            }
        }
    }
    close($fh);

    return %vt_data;
}

# ============================================================================
# Subroutine: Parse Synthesize.vt_group_details.json for Vt cell usage
# JSON format: [["VtGroup","Category","All",...], ["Low_Vt","Cell Count","160527",...], ...]
# ============================================================================
sub parse_vt_json {
    my ($json_file) = @_;

    my %vt_data;

    return %vt_data unless -e $json_file;

    open(my $fh, '<', $json_file) or return %vt_data;
    my $json_content = do { local $/; <$fh> };
    close($fh);

    # Simple JSON array parsing (no external modules needed)
    # Each row: ["VtGroup", "Category", "All", ...]
    # Categories: "Cell Count", "Cell Count %", "Area", "Area %"

    # Extract rows - look for patterns like ["Low_Vt", "Cell Count", "160527", ...]
    while ($json_content =~ /\["(\w+)",\s*"(Cell Count|Cell Count %|Area|Area %)",\s*"([\d.]+)"/g) {
        my $group = $1;
        my $category = $2;
        my $value = $3;

        # Skip header row and "Low vth groups" summary
        next if $group eq 'VtGroup' || $group =~ /^Low\s+vth/i;

        if ($category eq 'Cell Count') {
            if ($group eq 'Total') {
                $vt_data{total_cells} = $value;
            } else {
                $vt_data{groups}{$group}{count} = $value;
            }
        }
        elsif ($category eq 'Cell Count %') {
            if ($group ne 'Total') {
                $vt_data{groups}{$group}{count_pct} = $value;
            }
        }
        elsif ($category eq 'Area') {
            if ($group eq 'Total') {
                $vt_data{total_area} = $value;
            } else {
                $vt_data{groups}{$group}{area} = $value;
            }
        }
        elsif ($category eq 'Area %') {
            if ($group ne 'Total') {
                $vt_data{groups}{$group}{area_pct} = $value;
            }
        }

        # Track UltraLow_Vt for backward compatibility (closest to ULVTLL)
        if ($group eq 'UltraLow_Vt') {
            if ($category eq 'Cell Count') {
                $vt_data{ulvtll_count} = $value;
            }
            elsif ($category eq 'Cell Count %') {
                $vt_data{ulvtll_count_pct} = $value;
            }
            elsif ($category eq 'Area') {
                $vt_data{ulvtll_area} = $value;
            }
            elsif ($category eq 'Area %') {
                $vt_data{ulvtll_area_pct} = $value;
            }
        }
    }

    return %vt_data;
}

# ============================================================================
# Subroutine: Calculate Design metrics with auto-detection
# Priority: 1) totalCoreWNS/TNS/NVP, 2) *_r2r* groups, 3) UCLK group, 4) worst from all
# ============================================================================
sub calculate_design_metrics {
    my ($timing_data_ref) = @_;

    my $design_wns = 'N/A';
    my $design_tns = 0;
    my $design_nvp = 0;
    my $found_primary = 0;

    # Priority 1: Use totalCoreWNS/TNS/NVP if available (from FxSynthesize.dat)
    if (exists $timing_data_ref->{_totalCore}) {
        my $core = $timing_data_ref->{_totalCore};
        if (defined $core->{wns} && defined $core->{tns} && defined $core->{nvp}) {
            $design_wns = $core->{wns};
            $design_tns = $core->{tns};
            $design_nvp = $core->{nvp};
            $found_primary = 1;
        }
    }

    # Priority 2: Try to find *R2R* groups (case-insensitive)
    if (!$found_primary) {
        foreach my $group (keys %$timing_data_ref) {
            next if $group =~ /^_/;  # Skip internal keys like _totalCore
            if ($group =~ /R2R/i) {
                $found_primary = 1;

                my $wns = $timing_data_ref->{$group}{wns};
                my $tns = $timing_data_ref->{$group}{tns};
                my $nvp = $timing_data_ref->{$group}{nvp};

                if ($design_wns eq 'N/A' || $wns < $design_wns) {
                    $design_wns = $wns;
                }
                $design_tns += $tns if defined $tns;
                $design_nvp += $nvp if defined $nvp;
            }
        }
    }

    # Priority 3: If no r2r groups, try UCLK group (older flow)
    if (!$found_primary && exists $timing_data_ref->{UCLK}) {
        $found_primary = 1;
        $design_wns = $timing_data_ref->{UCLK}{wns};
        $design_tns = $timing_data_ref->{UCLK}{tns};
        $design_nvp = $timing_data_ref->{UCLK}{nvp};
    }

    # Priority 4: If still nothing, use worst WNS from all groups
    if (!$found_primary) {
        foreach my $group (keys %$timing_data_ref) {
            next if $group =~ /^_/;  # Skip internal keys
            my $wns = $timing_data_ref->{$group}{wns};
            my $tns = $timing_data_ref->{$group}{tns};
            my $nvp = $timing_data_ref->{$group}{nvp};

            if ($design_wns eq 'N/A' || $wns < $design_wns) {
                $design_wns = $wns;
            }
            $design_tns += $tns if defined $tns;
            $design_nvp += $nvp if defined $nvp;
            $found_primary = 1;
        }
    }

    # Format TNS to 2 decimal places
    $design_tns = sprintf("%.2f", $design_tns) if $found_primary;
    $design_tns = 'N/A' unless $found_primary;
    $design_nvp = 'N/A' unless $found_primary;

    return ($design_wns, $design_tns, $design_nvp);
}

# ============================================================================
# Subroutine: Identify primary timing groups (r2r or UCLK)
# ============================================================================
sub get_primary_timing_groups {
    my ($timing_data_ref) = @_;

    my @primary_groups;
    my @other_groups;

    # Check if we have r2r groups
    my $has_r2r = 0;
    foreach my $group (keys %$timing_data_ref) {
        if ($group =~ /R2R/i) {
            $has_r2r = 1;
            last;
        }
    }

    foreach my $group (keys %$timing_data_ref) {
        my $g = {
            name => $group,
            wns => $timing_data_ref->{$group}{wns},
            tns => $timing_data_ref->{$group}{tns},
            nvp => $timing_data_ref->{$group}{nvp}
        };

        if ($has_r2r) {
            # If we have r2r groups, use them as primary
            if ($group =~ /R2R/i) {
                push @primary_groups, $g;
            } else {
                push @other_groups, $g;
            }
        } else {
            # No r2r groups - use UCLK as primary if it exists
            if ($group eq 'UCLK') {
                push @primary_groups, $g;
            } else {
                push @other_groups, $g;
            }
        }
    }

    # Sort by WNS (worst first)
    @primary_groups = sort { $a->{wns} <=> $b->{wns} } @primary_groups;
    @other_groups = sort { $a->{wns} <=> $b->{wns} } @other_groups;

    return (\@primary_groups, \@other_groups);
}

# ============================================================================
# Subroutine: Parse Pass Progression Data (pass_1, pass_2, pass_3)
# ============================================================================
sub parse_pass_progression {
    my ($dir) = @_;

    my %pass_data;

    foreach my $pass_num (1, 2, 3) {
        # Parse proc_qor report for timing summary
        my $qor_file = "$dir/rpts/FxSynthesize/FxSynthesize.pass_${pass_num}.proc_qor.rpt.gz";
        if (-e $qor_file) {
            my ($design_wns, $tns, $nvp) = parse_proc_qor_summary($qor_file);
            $pass_data{$pass_num}{design_wns} = $design_wns;
            $pass_data{$pass_num}{tns} = $tns;
            $pass_data{$pass_num}{nvp} = $nvp;
        }

        # Parse multi_vt report for Vt usage
        my $vt_file = "$dir/rpts/FxSynthesize/multi_vt.pass_${pass_num}.rpt.gz";
        if (-e $vt_file) {
            my %vt_data = parse_multi_vt_report($vt_file);
            $pass_data{$pass_num}{ulvtll_pct} = $vt_data{ulvtll_count_pct};
            $pass_data{$pass_num}{total_cells} = $vt_data{total_cells};
        }
    }

    return %pass_data;
}

# ============================================================================
# Subroutine: Parse proc_qor report Summary line for Design WNS/TNS/NVP
# With auto-detection: r2r groups -> UCLK -> worst from all
# ============================================================================
sub parse_proc_qor_summary {
    my ($qor_file) = @_;

    my $design_wns = 'N/A';
    my $tns = 'N/A';
    my $nvp = 'N/A';

    return ($design_wns, $tns, $nvp) unless -e $qor_file;

    open(my $fh, "-|", "gzip -dc $qor_file 2>/dev/null") or return ($design_wns, $tns, $nvp);

    my $in_path_group_section = 0;
    my %all_groups;
    my $has_r2r = 0;
    my $has_uclk = 0;

    while (my $line = <$fh>) {
        # Detect path group table header
        if ($line =~ /Path Group\s+WNS\s+TNS\s+NVP/) {
            $in_path_group_section = 1;
            next;
        }

        # End of path group section (Summary line)
        if ($in_path_group_section && $line =~ /^Summary\s+/) {
            if ($line =~ /^Summary\s+(-?[\d.]+)\s+(-?[\d.]+)\s+(\d+)/) {
                $tns = $2;
                $nvp = $3;
            }
            last;
        }

        # Parse all group lines and store them
        if ($in_path_group_section && $line =~ /^\s*(\S+)\s+(-?[\d.]+)\s+(-?[\d.]+)\s+(\d+)/) {
            my $group = $1;
            my $wns = $2;

            $all_groups{$group} = $wns;

            if ($group =~ /R2R/i) {
                $has_r2r = 1;
            }
            if ($group eq 'UCLK') {
                $has_uclk = 1;
            }
        }
    }
    close($fh);

    # Priority 1: Use r2r groups
    if ($has_r2r) {
        foreach my $group (keys %all_groups) {
            if ($group =~ /R2R/i) {
                my $wns = $all_groups{$group};
                if ($design_wns eq 'N/A' || $wns < $design_wns) {
                    $design_wns = $wns;
                }
            }
        }
    }
    # Priority 2: Use UCLK group
    elsif ($has_uclk) {
        $design_wns = $all_groups{UCLK};
    }
    # Priority 3: Use worst from all
    else {
        foreach my $group (keys %all_groups) {
            my $wns = $all_groups{$group};
            if ($design_wns eq 'N/A' || $wns < $design_wns) {
                $design_wns = $wns;
            }
        }
    }

    # Format numbers
    $tns = sprintf("%.0f", $tns) if $tns ne 'N/A';

    return ($design_wns, $tns, $nvp);
}

# ============================================================================
# Subroutine: Parse block_area.rpt.gz for Area (legacy, kept for reference)
# ============================================================================
sub parse_area_report {
    my ($area_file) = @_;

    my $total_std_area = 0;
    my $total_mem_area = 0;

    return ($total_std_area, $total_mem_area) unless -e $area_file;

    open(my $fh, "-|", "gzip -dc $area_file") or return ($total_std_area, $total_mem_area);

    while (my $line = <$fh>) {
        # Parse BlockArea lines
        # Format: BlockArea: bpm_sdma 37.42128 37.42128 658 0 0
        # Fields: BlockName TotalArea StdArea StdcellCount MemoryArea MacroArea
        if ($line =~ /^BlockArea:\s+/) {
            my @columns = split(/\s+/, $line);

            if (scalar(@columns) >= 6) {
                my $std_area = $columns[3];
                my $mem_area = $columns[5];

                $total_std_area += $std_area if $std_area =~ /^[\d.]+$/;
                $total_mem_area += $mem_area if $mem_area =~ /^[\d.]+$/;
            }
        }
    }
    close($fh);

    # Round to 2 decimal places
    $total_std_area = sprintf("%.2f", $total_std_area);
    $total_mem_area = sprintf("%.2f", $total_mem_area);

    return ($total_std_area, $total_mem_area);
}
