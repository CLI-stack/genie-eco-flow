#!/bin/tcsh
# Script to send email notification when tasks are skipped
# Usage: send_skip_notification.csh <source_dir> <tag> <tile_name> <tile_dir> <skipped_tasks_file> <target_name>

if ($#argv != 6) then
    echo "Usage: $0 <source_dir> <tag> <tile_name> <tile_dir> <skipped_tasks_file> <target_name>"
    exit 1
endif

set source_dir = $1
set tag = $2
set tile_name = $3
set tile_dir = $4
set skipped_tasks_file = $5
set target_name = $6

echo "========================================================================"
echo "Sending skip notification email..."
echo "Tag: $tag"
echo "Tile: $tile_name"
echo "========================================================================"

# Create notification spec file
set notify_spec = "${source_dir}/data/${tag}_skip_notify.spec"
rm -f $notify_spec

# Write notification message
echo "#text#" >> $notify_spec
echo "NOTIFICATION: Waived Tasks Skipped" >> $notify_spec
echo "" >> $notify_spec
echo "The following waived tasks were skipped because their root causes matched the expected patterns:" >> $notify_spec
echo "" >> $notify_spec

# Add skipped tasks information
if (-f $skipped_tasks_file && -s $skipped_tasks_file) then
    echo "#table#" >> $notify_spec
    echo "Tile,Task,Status,Action" >> $notify_spec

    foreach task_name (`cat $skipped_tasks_file`)
        echo "${tile_name},${task_name},FAILED (Skipped),Re-running ${target_name}" >> $notify_spec
    end

    echo "#table end#" >> $notify_spec
else
    echo "No tasks were skipped." >> $notify_spec
endif

echo "" >> $notify_spec
echo "#text#" >> $notify_spec
echo "The target will be re-run automatically." >> $notify_spec
echo "This is an informational notification - no action required." >> $notify_spec
echo "" >> $notify_spec

# Get VTO name
source ${source_dir}/csh/env.csh
set vto = `cat assignment.csv | grep "vto," | head -n 1 | awk -F ',' '{print $2}' | sed 's/\r//g'`

# Add signature
echo "" >> $notify_spec
echo "Thanks," >> $notify_spec
echo "$vto (PD Agent)" >> $notify_spec
echo "" >> $notify_spec
echo "#line#" >> $notify_spec

# Convert spec to HTML - first create a temporary spec with proper email format
set email_spec = "${source_dir}/data/${tag}_skip_email.spec"
rm -f $email_spec

# Create email-formatted spec (similar to regular task completion)
echo "#text#" > $email_spec
echo "[SKIP NOTIFICATION] Waived Tasks Were Skipped" >> $email_spec
echo "" >> $email_spec
cat $notify_spec >> $email_spec

# Add quote section for email threading
echo "#text#" >> $email_spec
echo "-----Original Message-----" >> $email_spec

# Get original email body if available
set mail_body = `python ${source_dir}/py/readTask.py --tasksModelFile tasksModel.csv --tag $tag --item mailBody 2>/dev/null | tail -1`
if ("$mail_body" != "" && "$mail_body" != "None") then
    echo "$mail_body" >> $email_spec
endif

# Convert to HTML
set notify_html = "${source_dir}/data/${tag}_skip_notify.html"
python ${source_dir}/py/spec2Html.py --spec $email_spec --html $notify_html

# Send email directly using formail + sendmail (bypassing Python version issues)
echo "Sending notification email directly..."

# Get ALL recipients from assignment.csv (manager + all debuggers)
set recipients = ""

# Get manager
set manager = `cat assignment.csv | grep "manager," | head -n 1 | awk -F ',' '{print $2}' | sed 's/\r//g'`
if ("$manager" != "") then
    set recipients = "$manager"
endif

# Get ALL debuggers (not just the first one)
foreach debugger_line (`cat assignment.csv | grep "debugger," | awk -F ',' '{print $2}' | sed 's/\r//g'`)
    if ("$recipients" != "") then
        set recipients = "${recipients},${debugger_line}"
    else
        set recipients = "$debugger_line"
    endif
end

# Get original sender from tasksModel if available
set sender_email = `python ${source_dir}/py/readTask.py --tasksModelFile tasksModel.csv --tag $tag --item sender 2>/dev/null | tail -1`
if ("$sender_email" != "" && "$sender_email" != "None") then
    if ("$recipients" != "") then
        set recipients = "${recipients},${sender_email}"
    else
        set recipients = "$sender_email"
    endif
endif

# Get subject
set subject = `python ${source_dir}/py/readTask.py --tasksModelFile tasksModel.csv --tag $tag --item subject 2>/dev/null | tail -1`
if ("$subject" == "" || "$subject" == "None") then
    set subject = "TileBuilder Task Skip Notification"
endif

# Remove duplicate email addresses from recipients list
if ("$recipients" != "") then
    echo "$recipients" | tr ',' '\n' | sort -u > /tmp/recipients_unique_$$.tmp
    set recipients = `cat /tmp/recipients_unique_$$.tmp | tr '\n' ',' | sed 's/,$//'`
    rm -f /tmp/recipients_unique_$$.tmp
endif

echo "DEBUG: recipients = $recipients"
echo "DEBUG: subject = $subject"

# Send email using formail + sendmail
if ("$recipients" != "") then
    cat $notify_html | formail -I "To: $recipients" -I "From: $vto (PD Agent)" -I "MIME-Version: 1.0" -I "Content-type: text/html; charset=utf-8" -I "Subject: [SKIP NOTIFICATION] Re: $subject" | /sbin/sendmail -oi $recipients

    set mail_status = $status
    if ($mail_status == 0) then
        echo "✓ Skip notification email sent successfully to: $recipients"
    else
        echo "✗ Failed to send skip notification email (exit code: $mail_status)"
    endif
else
    echo "✗ WARNING: No recipients found - email not sent"
endif

# Cleanup
rm -f $skipped_tasks_file

echo "========================================================================"
