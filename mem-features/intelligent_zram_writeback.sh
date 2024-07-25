#!/system/bin/sh
# THANKS TO Dudu Ski, Xinlian, and Happy Little Sunshine123

# load libraries
CURR_DIR="$(dirname "$0")"
. $CURR_DIR/PATHS.sh

WRITEBACK_NUM=0
apps=""
app_switch=0
app_switch_threshold=""

# Checks ZRAM Writeback Support
zram_wb_support()
{
    if [ -f $ZRAM_SYS/writeback ] && [ -f $ZRAM_SYS/backing_dev ] && [ -f $ZRAM_SYS/idle ]; then
        echo "1"
    else
        echo "0"
    fi
}

# Configure the Backing Device for ZRAM (Xiaomi RAM Extension)
set_zram_writeback()
{
    if [ "$(zram_wb_support)" -eq 1 ] || [ "$(getprop persist.miui.extm.enable)" -eq "1" ]; then
        loop_device=$(losetup -f)
        loop_num=$(echo "$loop_device" | grep -Eo '[0-9]{1,2}')
        losetup $loop_device /data/extm/extm_file

        set_val "$loop_device" $ZRAM_SYS/backing_dev
        set_val "0" $ZRAM_SYS/writeback_limit_enable

        # Use "none" as the ZRAM Backing Dev scheduler and turn off iostats to reduce overhead
        set_val none > /sys/block/loop"$loop_num"/queue/scheduler
        set_val 0 > /sys/block/loop"$loop_num"/queue/iostats
    fi
}

# Activate ZRAM
zram_on()
{
    set_val "1" $ZRAM_SYS/reset
    set_val "$3" $ZRAM_SYS/comp_algorithm

    set_zram_writeback

    set_val "$1" $ZRAM_SYS/disksize
    set_val "$2" $ZRAM_SYS/mem_limit
    toybox mkswap $ZRAM_DEV
    toybox swapon $ZRAM_DEV -p 2024

    if [ "$(cat $ZRAM_SYS/backing_dev)" != "none" ]; then
        set_val "3" $VM/page-cluster
    else
        set_val "0" $VM/page-cluster
    fi

    # Disable ZRAM readahead
    set_val "0" $ZRAM_SYS/read_ahead_kb

    set_val 1 $ZRAM_SYS/use_dedup

    if [ "$enable_hybrid_swap" -eq 0 ]; then
        set_val "false" /sys/kernel/mm/swap/vma_ra_enabled
    fi
}

zram_get_comp_alg()
{
    local str
    str="$(cat $ZRAM_SYS/comp_algorithm)"
    echo "$str"
}

zram_status()
{
    local swap_info
    swap_info="$(cat /proc/swaps | grep "$ZRAM_DEV")"
    if [ "$swap_info" != "" ]; then
        echo "Enabled. Size $(echo "$swap_info" | awk '{print $3}')kB, using $(zram_get_comp_alg)."
    else
        echo "Disabled by user."
    fi
}


# Setup Automatic ZRAM Writeback after switching more than number of specified apps
auto_zram_writeback()
{

    # Default switch app threshold value
    app_switch_threshold="$(read_cfg app_switch_threshold)"
    [ "$app_switch_threshold" == "" ] && app_switch_threshold=10

    if [ "$(cat "$ZRAM_SYS"/backing_dev)" != "none" ] && [ "$(zram_writeback_support)" -eq 1 ]; then
        while [ "$(cat "$ZRAM_SYS"/backing_dev)" != "none" ]; do
            APP=$(dumpsys activity lru | grep 'TOP' | awk 'NR==1' | awk -F '[ :/]+' '{print $7}')
            mem_total=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
            mem_avail=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)
            min_mem_avail=$(awk '/^MemTotal:/{print int($2/5)}' /proc/meminfo)
  
            # Checks if Memory Usage is 80% and if screen is off
            if [ "$mem_avail" -le "$min_mem_avail" ]; then
                display_state=$(dumpsys display | awk -F "=" '/mScreenState/ {print $2}')
                if [ "$display_state" == "OFF" ]; then
                    set_val all $ZRAM_SYS/idle
                    set_val idle $ZRAM_SYS/writeback
                    app_switch=0
                fi
            fi
  
            # Checks app switching, ignore when screen is off
            if [ "$APP" != "$apps" ]; then
                if [ -z "$APP" ]; then
                    app_switch=$((app_switch + 0))
                else
                    app_switch=$((app_switch + 1))
                fi
            fi
    
            # Execute ZRAM writeback when app switches more than the number specified
            if [ "$app_switch" -gt $app_switch_threshold ]; then
                display_state=$(dumpsys display | awk -F "=" '/mScreenState/ {print $2}')
                if [ "$WRITEBACK_NUM" -gt 4 ]; then
                    WRITEBACK_NUM=0
                fi
                if [ "$WRITEBACK_NUM" -eq 4 ] && [ "$display_state" == "OFF" ]; then
                    set_val all $ZRAM_SYS/idle
                    set_val idle $ZRAM_SYS/writeback
                    WRITEBACK_NUM=$((WRITEBACK_NUM + 1))
                    app_switch=0
                else
                    if [ "$WRITEBACK_NUM" -lt 4 ]; then
                        set_val huge $ZRAM_SYS/writeback 
                        WRITEBACK_NUM=$((WRITEBACK_NUM + 1))
                        app_switch=0
                    fi
                fi
            fi
  
        apps="$APP"
        sleep 10
  
    done &
fi
}