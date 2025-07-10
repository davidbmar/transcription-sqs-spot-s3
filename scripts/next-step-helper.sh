#!/bin/bash

# next-step-helper.sh - Generic function to automatically determine next script in sequence

# Function to show the next step in the sequence
show_next_step() {
    local current_script="$1"
    local script_dir="$2"
    
    # Default to current directory if script_dir not provided
    if [ -z "$script_dir" ]; then
        script_dir="$(dirname "$0")"
    fi
    
    # Get just the filename without path
    local current_filename=$(basename "$current_script")
    
    # Get all step-xxx scripts in the same series (same hundred)
    local current_series=$(echo "$current_filename" | grep -o 'step-[0-9]\+' | grep -o '[0-9]\+')
    local series_prefix="${current_series:0:1}00"  # Get first digit + "00" (e.g., 100, 200, 300)
    
    # Find all scripts in the same series, sorted
    local all_scripts=$(ls "$script_dir"/step-${series_prefix:0:1}*.sh 2>/dev/null | sort)
    
    # Find the current script position
    local found_current=false
    local next_script=""
    
    for script in $all_scripts; do
        local script_name=$(basename "$script")
        
        if [ "$found_current" = true ]; then
            # Skip divider files (contain "=-=-=-=-=")
            if [[ "$script_name" != *"=-=-=-=-="* ]]; then
                next_script="$script"
                break
            fi
        fi
        
        if [ "$script_name" = "$current_filename" ]; then
            found_current=true
        fi
    done
    
    # Display results
    echo ""
    echo "📋 NEXT STEP IN SEQUENCE:"
    if [ -n "$next_script" ]; then
        local next_name=$(basename "$next_script")
        # Show path relative to current working directory
        local current_dir=$(basename "$(pwd)")
        if [[ "$current_dir" != "scripts" ]]; then
            echo "   ./scripts/$next_name"
        else
            echo "   ./$next_name"
        fi
        
        # Try to get a description from the script header
        local description=$(head -5 "$next_script" 2>/dev/null | grep -E '^#.*-.*' | head -1 | sed 's/^#[[:space:]]*//' | sed 's/step-[0-9]*-[^[:space:]]*//' | sed 's/^[[:space:]]*//')
        if [ -n "$description" ]; then
            echo "   📝 $description"
        fi
    else
        # Check if we're at the end of this series
        echo "   ✅ Series complete! Check other deployment paths:"
        echo "   📊 PATH 100 (DLAMI): step-100-=-=-=-=-=DLAMI-ONDEMAND-TURNKEY=-=-=--=-=-.sh"
        echo "   💰 PATH 200 (Ubuntu+Spot): step-200-=-=-=-=-=UBUNTU-MANUAL-SPOT=-=-=--=-=-.sh"  
        echo "   🐳 PATH 300 (Docker+Spot): step-300-=-=-=-=-=UBUNTU-DOCKER-SPOT=-=-=--=-=-.sh"
    fi
    echo ""
}

# Function to show the current series overview
show_series_overview() {
    local current_script="$1"
    local script_dir="$2"
    
    # Default to current directory if script_dir not provided
    if [ -z "$script_dir" ]; then
        script_dir="$(dirname "$0")"
    fi
    
    local current_filename=$(basename "$current_script")
    local current_series=$(echo "$current_filename" | grep -o 'step-[0-9]\+' | grep -o '[0-9]\+')
    local series_prefix="${current_series:0:1}00"
    
    echo ""
    echo "📊 CURRENT SERIES OVERVIEW:"
    
    # Get series name from divider file
    local divider_file=$(ls "$script_dir"/step-${series_prefix:0:1}*=-=-=-=-*.sh 2>/dev/null | head -1)
    if [ -n "$divider_file" ]; then
        local series_name=$(basename "$divider_file" | sed 's/step-[0-9]*-=-=-=-=-=//' | sed 's/=-=-=--=-=-.sh//' | tr '-' ' ')
        echo "   🏷️  PATH ${series_prefix:0:1}00: $series_name"
    fi
    
    # Show all scripts in series with status
    local all_scripts=$(ls "$script_dir"/step-${series_prefix:0:1}*.sh 2>/dev/null | grep -v "=-=-=-=-=" | sort)
    local current_reached=false
    
    for script in $all_scripts; do
        local script_name=$(basename "$script")
        local step_num=$(echo "$script_name" | grep -o 'step-[0-9]\+' | grep -o '[0-9]\+')
        
        if [ "$script_name" = "$current_filename" ]; then
            echo "   ➤  $script_name (CURRENT)"
            current_reached=true
        elif [ "$current_reached" = false ]; then
            echo "   ✅ $script_name"
        else
            echo "   ⏳ $script_name"
        fi
    done
    echo ""
}

# Note: Auto-detection removed to prevent duplicate calls
# Scripts should manually call: show_next_step "$0" "$(dirname "$0")"