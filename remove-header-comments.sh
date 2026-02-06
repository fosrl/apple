#!/bin/bash

# Script to remove top-level header comments from Swift files
# Removes consecutive comment lines (starting with //) and blank lines at the top of files

# Function to remove header comments from a single file
remove_header_comments() {
    local file="$1"
    local temp_file=$(mktemp)
    
    # Use awk to skip comment lines and blank lines at the start
    # Keep everything after the first non-comment, non-blank line
    awk '
    BEGIN { in_header = 1 }
    in_header && /^\/\// { next }  # Skip comment lines
    in_header && /^$/ { next }     # Skip blank lines in header
    { 
        in_header = 0
        print
    }
    ' "$file" > "$temp_file"
    
    # Only replace the original file if changes were made
    if ! cmp -s "$file" "$temp_file"; then
        mv "$temp_file" "$file"
        echo "Removed header comments from: $file"
    else
        rm "$temp_file"
    fi
}

# Find all Swift files and process them
find . -name "*.swift" -type f | while read -r file; do
    remove_header_comments "$file"
done

echo "Done processing Swift files."
