#!/bin/bash

# PGFS File System Image Creator
# - Block size: 512 bytes
# - Chunk size: 128 blocks (64 KB)
# - FileBlock: 16-byte name + 4-byte size + 246 uint16 chunk IDs = 512 bytes
# - Superblock: 4 uint32 values (B, F, C, N) = 16 bytes (padded to 512)

set -e

# Constants
BLOCK_SIZE=512
BLOCKS_PER_CHUNK=128
CHUNK_SIZE=$((BLOCK_SIZE * BLOCKS_PER_CHUNK))  # 65536 bytes (64 KB)
FILEBLOCK_NAME_SIZE=16
FILEBLOCK_SIZE_FIELD=4
FILEBLOCK_MAX_CHUNKS=246
FILEBLOCK_TOTAL=$BLOCK_SIZE

# Default configuration
MAX_FILES=64
MAX_CHUNKS=256
OUTPUT_FILE="ktfs.raw"

usage() {
    echo "GOONIX File System Image Creator"
    echo ""
    echo "Usage: $0 [OPTIONS] file1 [file2 ...]"
    echo ""
    echo "Options:"
    echo "  -o, --output FILE    Output image filename (default: goonix.img)"
    echo "  -f, --max-files N    Maximum number of files (default: 64)"
    echo "  -c, --max-chunks N   Maximum number of chunks (default: 256)"
    echo "  -h, --help           Show this help message"
    echo ""
    echo "File System Layout:"
    echo "  [Superblock][Bitmap Blocks][FileBlocks][Data Chunks...]"
    echo ""
    echo "Specifications:"
    echo "  Block size:    512 bytes"
    echo "  Chunk size:    128 blocks (64 KB)"
    echo "  FileBlock:     16-byte name, 4-byte size, 246 chunk IDs"
    exit 1
}

# Parse arguments
FILES=()
while [[ $# -gt 0 ]]; do
    case $1 in
        -o|--output)
            OUTPUT_FILE="$2"
            shift 2
            ;;
        -f|--max-files)
            MAX_FILES="$2"
            shift 2
            ;;
        -c|--max-chunks)
            MAX_CHUNKS="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        -*)
            echo "Unknown option: $1"
            usage
            ;;
        *)
            FILES+=("$1")
            shift
            ;;
    esac
done

if [[ ${#FILES[@]} -eq 0 ]]; then
    echo "Error: No input files specified"
    usage
fi

# Calculate bitmap size (1 bit per chunk, rounded up to blocks)
BITMAP_BITS=$MAX_CHUNKS
BITMAP_BYTES=$(( (BITMAP_BITS + 7) / 8 ))
BITMAP_BLOCKS=$(( (BITMAP_BYTES + BLOCK_SIZE - 1) / BLOCK_SIZE ))

# Calculate fileblock area size
FILEBLOCK_BLOCKS=$MAX_FILES  # Each fileblock is exactly one block

echo "=== GOONIX File System Creator ==="
echo "Output file:     $OUTPUT_FILE"
echo "Max files:       $MAX_FILES"
echo "Max chunks:      $MAX_CHUNKS"
echo "Bitmap blocks:   $BITMAP_BLOCKS"
echo "FileBlock blocks: $FILEBLOCK_BLOCKS"
echo "Input files:     ${#FILES[@]}"
echo ""

# Create temporary working directory
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

# Helper function to write a little-endian uint32
write_uint32() {
    local val=$1
    local file=$2
    printf "\\x$(printf '%02x' $((val & 0xFF)))" >> "$file"
    printf "\\x$(printf '%02x' $(((val >> 8) & 0xFF)))" >> "$file"
    printf "\\x$(printf '%02x' $(((val >> 16) & 0xFF)))" >> "$file"
    printf "\\x$(printf '%02x' $(((val >> 24) & 0xFF)))" >> "$file"
}

# Helper function to write a little-endian uint16
write_uint16() {
    local val=$1
    local file=$2
    printf "\\x$(printf '%02x' $((val & 0xFF)))" >> "$file"
    printf "\\x$(printf '%02x' $(((val >> 8) & 0xFF)))" >> "$file"
}

# Helper function to pad file to specified size with zeros
pad_to_size() {
    local file=$1
    local target_size=$2
    local current_size=$(stat -c%s "$file" 2>/dev/null || stat -f%z "$file" 2>/dev/null)
    local padding=$((target_size - current_size))
    if [[ $padding -gt 0 ]]; then
        dd if=/dev/zero bs=1 count=$padding >> "$file" 2>/dev/null
    fi
}

# Chunk allocation tracking
NEXT_FREE_CHUNK=0

# Process all files and collect metadata
echo "Processing files..."

# We'll store file info in parallel arrays
declare -a FILE_NAMES
declare -a FILE_SIZES
declare -a FILE_PATHS
declare -a FILE_CHUNK_IDS  # Space-separated chunk IDs per file

NUM_FILES=0
for filepath in "${FILES[@]}"; do
    if [[ ! -f "$filepath" ]]; then
        echo "Warning: File not found: $filepath (skipping)"
        continue
    fi
    
    if [[ $NUM_FILES -ge $MAX_FILES ]]; then
        echo "Warning: Maximum files ($MAX_FILES) reached, skipping: $filepath"
        continue
    fi
    
    filename=$(basename "$filepath")
    filesize=$(stat -c%s "$filepath" 2>/dev/null || stat -f%z "$filepath" 2>/dev/null)
    
    # Truncate filename to 15 chars (leave room for null terminator)
    if [[ ${#filename} -gt 15 ]]; then
        filename="${filename:0:15}"
    fi
    
    # Calculate chunks needed
    chunks_needed=$(( (filesize + CHUNK_SIZE - 1) / CHUNK_SIZE ))
    if [[ $chunks_needed -eq 0 ]]; then
        chunks_needed=1  # Even empty files get at least one chunk
    fi
    
    if [[ $chunks_needed -gt $FILEBLOCK_MAX_CHUNKS ]]; then
        echo "Warning: File too large (needs $chunks_needed chunks, max $FILEBLOCK_MAX_CHUNKS): $filepath (skipping)"
        continue
    fi
    
    # Check if we have enough chunks
    if [[ $((NEXT_FREE_CHUNK + chunks_needed)) -gt $MAX_CHUNKS ]]; then
        echo "Error: Out of chunks while processing: $filepath"
        echo "  Need $chunks_needed chunks, only $((MAX_CHUNKS - NEXT_FREE_CHUNK)) available"
        exit 1
    fi
    
    # Allocate chunks sequentially
    chunk_ids=""
    for ((c = 0; c < chunks_needed; c++)); do
        if [[ -n "$chunk_ids" ]]; then
            chunk_ids="$chunk_ids $NEXT_FREE_CHUNK"
        else
            chunk_ids="$NEXT_FREE_CHUNK"
        fi
        NEXT_FREE_CHUNK=$((NEXT_FREE_CHUNK + 1))
    done
    
    echo "  $filename: $filesize bytes, $chunks_needed chunk(s) [$chunk_ids]"
    
    # Store metadata
    FILE_NAMES[$NUM_FILES]="$filename"
    FILE_SIZES[$NUM_FILES]="$filesize"
    FILE_PATHS[$NUM_FILES]="$filepath"
    FILE_CHUNK_IDS[$NUM_FILES]="$chunk_ids"
    
    NUM_FILES=$((NUM_FILES + 1))
done

USED_CHUNKS=$NEXT_FREE_CHUNK

echo ""
echo "Total files: $NUM_FILES"
echo "Used chunks: $USED_CHUNKS / $MAX_CHUNKS"
echo ""

# === Write Superblock ===
echo "Writing superblock..."
SUPERBLOCK="$TMPDIR/superblock.bin"
> "$SUPERBLOCK"

# Superblock structure:
# uint32 B - Number of bitmap blocks
# uint32 F - Max files
# uint32 C - Max chunks  
# uint32 N - Current number of files
write_uint32 $BITMAP_BLOCKS "$SUPERBLOCK"
write_uint32 $MAX_FILES "$SUPERBLOCK"
write_uint32 $MAX_CHUNKS "$SUPERBLOCK"
write_uint32 $NUM_FILES "$SUPERBLOCK"

# Pad superblock to one full block
pad_to_size "$SUPERBLOCK" $BLOCK_SIZE

# === Write Bitmap Blocks ===
echo "Writing bitmap blocks..."
BITMAP_FILE="$TMPDIR/bitmap.bin"
> "$BITMAP_FILE"

# Build bitmap - first USED_CHUNKS bits are 1, rest are 0
current_byte=0
bit=0
for ((i = 0; i < MAX_CHUNKS; i++)); do
    if [[ $i -lt $USED_CHUNKS ]]; then
        current_byte=$((current_byte | (1 << bit)))
    fi
    bit=$((bit + 1))
    if [[ $bit -eq 8 ]]; then
        printf "\\x$(printf '%02x' $current_byte)" >> "$BITMAP_FILE"
        current_byte=0
        bit=0
    fi
done

# Write remaining bits if any
if [[ $bit -ne 0 ]]; then
    printf "\\x$(printf '%02x' $current_byte)" >> "$BITMAP_FILE"
fi

# Pad bitmap to block boundary
pad_to_size "$BITMAP_FILE" $((BITMAP_BLOCKS * BLOCK_SIZE))

# === Write FileBlocks ===
echo "Writing fileblocks..."
FILEBLOCKS="$TMPDIR/fileblocks.bin"
> "$FILEBLOCKS"

for ((fidx = 0; fidx < NUM_FILES; fidx++)); do
    name="${FILE_NAMES[$fidx]}"
    size="${FILE_SIZES[$fidx]}"
    chunk_ids_str="${FILE_CHUNK_IDS[$fidx]}"
    read -ra chunk_ids <<< "$chunk_ids_str"
    
    # Create single fileblock
    FB="$TMPDIR/fb_temp.bin"
    > "$FB"
    
    # Write name (16 bytes, null-padded)
    name_len=${#name}
    echo -n "$name" >> "$FB"
    # Pad name to 16 bytes with nulls
    for ((p = name_len; p < 16; p++)); do
        printf '\x00' >> "$FB"
    done
    
    # Write size (uint32)
    write_uint32 $size "$FB"
    
    # Write chunk IDs (246 uint16 values)
    for ((i = 0; i < FILEBLOCK_MAX_CHUNKS; i++)); do
        if [[ $i -lt ${#chunk_ids[@]} ]]; then
            write_uint16 ${chunk_ids[$i]} "$FB"
        else
            write_uint16 0 "$FB"  # Unused slots are 0
        fi
    done
    
    cat "$FB" >> "$FILEBLOCKS"
done

# Pad fileblocks area with empty fileblocks
for ((fidx = NUM_FILES; fidx < MAX_FILES; fidx++)); do
    dd if=/dev/zero bs=$BLOCK_SIZE count=1 >> "$FILEBLOCKS" 2>/dev/null
done

# === Write Data Chunks ===
echo "Writing data chunks..."
CHUNKS_FILE="$TMPDIR/chunks.bin"

# Initialize all chunks with zeros
dd if=/dev/zero of="$CHUNKS_FILE" bs=$CHUNK_SIZE count=$MAX_CHUNKS 2>/dev/null

# Write actual file data into their chunks
for ((fidx = 0; fidx < NUM_FILES; fidx++)); do
    filepath="${FILE_PATHS[$fidx]}"
    size="${FILE_SIZES[$fidx]}"
    chunk_ids_str="${FILE_CHUNK_IDS[$fidx]}"
    read -ra chunk_ids <<< "$chunk_ids_str"
    
    # Read file and write to chunks
    bytes_remaining=$size
    chunk_idx=0
    
    while [[ $bytes_remaining -gt 0 && $chunk_idx -lt ${#chunk_ids[@]} ]]; do
        chunk_id=${chunk_ids[$chunk_idx]}
        bytes_to_write=$CHUNK_SIZE
        if [[ $bytes_remaining -lt $bytes_to_write ]]; then
            bytes_to_write=$bytes_remaining
        fi
        
        # Calculate offset in chunks file
        chunk_offset=$((chunk_id * CHUNK_SIZE))
        
        # Extract portion of source file and write to chunk location
        skip_bytes=$((chunk_idx * CHUNK_SIZE))
        dd if="$filepath" of="$CHUNKS_FILE" bs=1 skip=$skip_bytes seek=$chunk_offset count=$bytes_to_write conv=notrunc 2>/dev/null
        
        bytes_remaining=$((bytes_remaining - bytes_to_write))
        chunk_idx=$((chunk_idx + 1))
    done
done

# === Assemble final image ===
echo "Assembling final image..."
cat "$SUPERBLOCK" "$BITMAP_FILE" "$FILEBLOCKS" "$CHUNKS_FILE" > "$OUTPUT_FILE"

FINAL_SIZE=$(stat -c%s "$OUTPUT_FILE" 2>/dev/null || stat -f%z "$OUTPUT_FILE" 2>/dev/null)
echo ""
echo "=== Image created successfully ==="
echo "Output:     $OUTPUT_FILE"
echo "Size:       $FINAL_SIZE bytes ($((FINAL_SIZE / 1024)) KB)"
echo ""
echo "Layout:"
echo "  Superblock:   0x0000 - 0x$(printf '%04X' $((BLOCK_SIZE - 1))) ($BLOCK_SIZE bytes)"

BITMAP_START=$BLOCK_SIZE
BITMAP_END=$((BITMAP_START + BITMAP_BLOCKS * BLOCK_SIZE - 1))
echo "  Bitmap:       0x$(printf '%04X' $BITMAP_START) - 0x$(printf '%04X' $BITMAP_END) ($((BITMAP_BLOCKS * BLOCK_SIZE)) bytes)"

FB_START=$((BITMAP_END + 1))
FB_END=$((FB_START + MAX_FILES * BLOCK_SIZE - 1))
echo "  FileBlocks:   0x$(printf '%04X' $FB_START) - 0x$(printf '%04X' $FB_END) ($((MAX_FILES * BLOCK_SIZE)) bytes)"

DATA_START=$((FB_END + 1))
DATA_END=$((DATA_START + MAX_CHUNKS * CHUNK_SIZE - 1))
echo "  Data Chunks:  0x$(printf '%04X' $DATA_START) - 0x$(printf '%08X' $DATA_END) ($((MAX_CHUNKS * CHUNK_SIZE)) bytes)"

echo ""
echo "Files in image:"
for ((fidx = 0; fidx < NUM_FILES; fidx++)); do
    printf "  [%d] %-16s %8d bytes  chunks: %s\n" $fidx "${FILE_NAMES[$fidx]}" "${FILE_SIZES[$fidx]}" "${FILE_CHUNK_IDS[$fidx]}"
done

echo ""
echo "Done!"