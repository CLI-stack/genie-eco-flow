#!/bin/tcsh
# List TileBuilder directories in a tiles directory
# Usage: list_tilebuilder_dirs.csh <tiles_dir> <tag>
# A TileBuilder directory is identified by having a revrc.main file

set tiles_dir = $1
set tag = $2
set source_dir = `pwd`
touch $source_dir/data/${tag}_spec

# Parse parameters
set tilesdir_name = `echo $tiles_dir | sed 's/:/ /g' | awk '{$1="";print $0}'`

# Validate input
if ("$tilesdir_name" == "" || "$tilesdir_name" == " ") then
    echo "ERROR: tiles_dir is empty or invalid" >> $source_dir/data/${tag}_spec
    echo "Usage: list_tilebuilder_dirs.csh <tiles_dir> <tag>" >> $source_dir/data/${tag}_spec
    exit 1
endif

# Check if directory exists
if (! -d $tilesdir_name) then
    echo "ERROR: Directory not found: $tilesdir_name" >> $source_dir/data/${tag}_spec
    exit 1
endif

# Check if directory ends with "tiles"
set basename_dir = `basename $tilesdir_name`
if ("$basename_dir" != "tiles") then
    echo "ERROR: Directory must end with 'tiles'" >> $source_dir/data/${tag}_spec
    echo "Provided: $tilesdir_name" >> $source_dir/data/${tag}_spec
    exit 1
endif

echo "Scanning for TileBuilder directories in: $tilesdir_name"

# Output header
echo "#text#" >> $source_dir/data/${tag}_spec
echo "TileBuilder Directories" >> $source_dir/data/${tag}_spec
echo "========================================" >> $source_dir/data/${tag}_spec
echo "Tiles Directory: $tilesdir_name" >> $source_dir/data/${tag}_spec
echo "" >> $source_dir/data/${tag}_spec
echo "#table#" >> $source_dir/data/${tag}_spec
echo "Directory,Type,ModifiedDate" >> $source_dir/data/${tag}_spec

# Scan all subdirectories
set found_count = 0

foreach dir (`ls -d $tilesdir_name/*/`)
    set dir_name = `basename $dir`
    
    # Check if revrc.main exists
    if (-f "$dir/revrc.main") then
        set dir_type = "TileBuilder"
        set mod_date = `ls -ld $dir | awk '{print $6, $7, $8}'`
        
        echo "$dir,$dir_type,$mod_date" >> $source_dir/data/${tag}_spec
        @ found_count++
    endif
end

echo "#table end#" >> $source_dir/data/${tag}_spec

# Summary
echo "" >> $source_dir/data/${tag}_spec
echo "Summary:" >> $source_dir/data/${tag}_spec
echo "  Total TileBuilder directories found: $found_count" >> $source_dir/data/${tag}_spec
echo "========================================" >> $source_dir/data/${tag}_spec

echo "Found $found_count TileBuilder directories"
