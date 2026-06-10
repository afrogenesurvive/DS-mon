#!/usr/bin/env python3
"""
Generate Apple ICNS icon from a source PNG image.
Usage: gen_icns.py <input_png> <output_icns>

On macOS 26+, iconutil no longer supports converting iconset -> icns,
so we build the ICNS binary format directly.
"""
import struct
import zlib
import subprocess
import sys
import os
import tempfile

def add_alpha_channel(png_data):
    """Convert an RGB PNG to RGBA (add opaque alpha channel)."""
    pos = 8
    chunks = []
    while pos < len(png_data):
        length = struct.unpack('>I', png_data[pos:pos+4])[0]
        ctype = png_data[pos+4:pos+8]
        data = png_data[pos+8:pos+8+length]
        chunks.append((ctype, data))
        pos += 12 + length
    
    ihdr_data = None
    for ctype, data in chunks:
        if ctype == b'IHDR':
            ihdr_data = data
            break
    
    if ihdr_data is None:
        raise ValueError("No IHDR chunk found")
    
    w, h = struct.unpack('>II', ihdr_data[:8])
    bit_depth = ihdr_data[8]
    color_type = ihdr_data[9]
    
    if color_type == 6:  # Already RGBA
        return png_data
    
    if color_type != 2:  # Not RGB
        raise ValueError(f"Unsupported color type: {color_type}")
    
    raw_data = b''
    for ctype, data in chunks:
        if ctype == b'IDAT':
            raw_data += data
    decompressed = zlib.decompress(raw_data)
    
    new_rows = []
    row_len = w * 3 + 1
    for i in range(h):
        row_start = i * row_len
        row = decompressed[row_start:row_start + row_len]
        filter_byte = row[0:1]
        rgb = row[1:]
        new_row = filter_byte + b''.join(rgb[j:j+3] + b'\xff' for j in range(0, len(rgb), 3))
        new_rows.append(new_row)
    
    new_raw = b''.join(new_rows)
    compressed_new = zlib.compress(new_raw)
    
    def make_chunk(ctype, data):
        c = ctype + data
        return struct.pack('>I', len(data)) + c + struct.pack('>I', zlib.crc32(c) & 0xffffffff)
    
    new_ihdr = struct.pack('>IIBBBBB', w, h, bit_depth, 6, 0, 0, 0)
    output = b'\x89PNG\r\n\x1a\n'
    output += make_chunk(b'IHDR', new_ihdr)
    output += make_chunk(b'IDAT', compressed_new)
    output += make_chunk(b'IEND', b'')
    return output


def resize_png(png_path, size, output_path):
    """Resize a PNG using sips."""
    result = subprocess.run(
        ['sips', '-z', str(size), str(size), png_path, '--out', output_path],
        capture_output=True
    )
    if result.returncode != 0:
        raise RuntimeError(f"sips resize failed: {result.stderr.decode()}")


def create_icns(source_png, output_icns):
    """Create ICNS file from source PNG."""
    tmpdir = tempfile.mkdtemp(prefix='icns_')
    try:
        # Icon type codes for different sizes
        sizes = [
            (16, b'ic04'),
            (32, b'ic05'),
            (128, b'ic07'),
            (256, b'ic08'),
            (512, b'ic09'),
            (1024, b'ic10'),
        ]
        
        entries = []
        for size, icon_type in sizes:
            # Resize
            resized_path = os.path.join(tmpdir, f'icon_{size}.png')
            resize_png(source_png, size, resized_path)
            
            # Read and add alpha
            with open(resized_path, 'rb') as f:
                png_data = f.read()
            rgba_data = add_alpha_channel(png_data)
            entries.append((icon_type, rgba_data))
        
        # Build ICNS
        total_size = 8  # header
        for icon_type, png_data in entries:
            total_size += 8 + len(png_data)
        
        with open(output_icns, 'wb') as f:
            f.write(b'icns')
            f.write(struct.pack('>I', total_size))
            for icon_type, png_data in entries:
                f.write(icon_type)
                f.write(struct.pack('>I', 8 + len(png_data)))
                f.write(png_data)
        
        return output_icns
    finally:
        # Clean up temp files
        for f in os.listdir(tmpdir):
            os.remove(os.path.join(tmpdir, f))
        os.rmdir(tmpdir)


if __name__ == '__main__':
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <input_png> <output_icns>", file=sys.stderr)
        sys.exit(1)
    
    input_png = sys.argv[1]
    output_icns = sys.argv[2]
    
    if not os.path.isfile(input_png):
        print(f"Error: input file not found: {input_png}", file=sys.stderr)
        sys.exit(1)
    
    create_icns(input_png, output_icns)
    file_size = os.path.getsize(output_icns)
    print(f"✅ ICNS generated: {output_icns} ({file_size} bytes)")
