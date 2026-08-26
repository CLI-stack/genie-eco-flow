#!/bin/tcsh

set refDir = $1
set tag = $2
set source_dir = `pwd`
touch $source_dir/data/${tag}_spec


set refdir_name = `echo $refDir | sed 's/:/ /g' | awk '{$1="";print $0}'`
set tile_path = "$refdir_name"

# Verify path exists
if (! -d "$tile_path") then
    echo "Error: Directory does not exist: $tile_path" >> $source_dir/data/${tag}_spec
    source $source_dir/script/rtg_oss_feint/finishing_task.csh
endif

if (! -f "$tile_path/revrc.main") then
    echo "Error: revrc.main not found in $tile_path" >> $source_dir/data/${tag}_spec
    echo "This is not a valid TileBuilder directory or cannot be deleted" >> $source_dir/data/${tag}_spec
    source $source_dir/script/rtg_oss_feint/finishing_task.csh
endif

set tile_name = `basename $tile_path`
set parent_dir = `dirname $tile_path`

cd $tile_path

# Create log file
set log_file = "${parent_dir}/tilebuilder_delete_${tile_name}.log"

echo "Running TileBuilderDeleteFlow --destroy $tile_name"
TileBuilderTerm -x "cd $parent_dir && TileBuilderDeleteFlow --destroy $tile_name >& $log_file" &

echo "Monitoring deletion process..."
echo "Log file: $log_file"

# Monitor log file for completion
set max_wait = 300
set elapsed = 0
set success = 0
set error = 0

while ($elapsed < $max_wait)
    if (-f $log_file) then
        set success = `grep "done after 0s" $log_file | wc -l`
        set error = `grep "ERROR" $log_file | wc -l`
        
        if ($success > 0 || $error > 0) then
            echo "Deletion completed (elapsed: $elapsed seconds)"
            break
        endif
    endif
    
    sleep 5
    @ elapsed += 5
    
    if ($elapsed % 30 == 0) then
        echo "Still running... ($elapsed seconds)"
    endif
end

if ($elapsed >= $max_wait) then
    echo "WARNING: Timeout reached after $max_wait seconds"
endif

# Check both log and directory
set dir_exists = 0
if (-d $tile_path) then
    set dir_exists = 1
endif

if ($success > 0 && $dir_exists == 0) then
    echo "" >> $source_dir/data/${tag}_spec
    echo "SUCCESS: $tile_path has been deleted" >> $source_dir/data/${tag}_spec
else if ($error > 0 || $dir_exists == 1) then
    echo "" >> $source_dir/data/${tag}_spec
    echo "ERROR: Deletion failed" >> $source_dir/data/${tag}_spec
    if ($error > 0) then
        echo "  - Log shows ERROR" >> $source_dir/data/${tag}_spec
    endif
    if ($dir_exists == 1) then
        echo "  - Directory still exists: $tile_path" >> $source_dir/data/${tag}_spec
    endif
else
    echo "" >> $source_dir/data/${tag}_spec
    echo "WARNING: Unclear deletion status" >> $source_dir/data/${tag}_spec
endif

rm -rf $log_file

source $source_dir/script/rtg_oss_feint/finishing_task.csh
