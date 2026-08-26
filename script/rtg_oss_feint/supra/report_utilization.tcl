#!/bin/tcsh
# TCL script to report design utilization in Fusion Compiler / ICC2
# Usage: source report_utilization.tcl
# Expects AGENT_TAG environment variable to be set

# Get design name
set design_name [get_object_name [current_design]]
set timestamp [clock format [clock seconds] -format "%Y-%m-%d %H:%M:%S"]

# Get tag from environment variable (default to "report" if not set)
if {[info exists env(AGENT_TAG)]} {
    set tag $env(AGENT_TAG)
} else {
    set tag "report"
}

# Create reports directory if it doesn't exist
if {![file exists reports]} {
    file mkdir reports
}

# Set report filename with tag
set report_file "reports/agent_utilization_report_${tag}.rpt"

# Open report file
set fh [open $report_file w]

puts $fh "################################################################################"
puts $fh "# Utilization Report"
puts $fh "# Design: $design_name"
puts $fh "# Date: $timestamp"
puts $fh "################################################################################"
puts $fh ""

close $fh

# Report basic utilization to file
puts "Generating utilization report: $report_file"
redirect -append $report_file {
    report_utilization
}

puts "Utilization report generated: $report_file"
