#!/usr/bin/env python3
"""
Generate Apple ICNS icon from a source PNG image.
Usage: gen_icns.py <input_png> <output_icns>

Uses sips for resize — embeds the PNG directly into ICNS without 
Python re-compression. Source image should be opaque RGB or RGBA.
"""
import struct
import subprocess
import sys
import os
import tempfile

def create_icns(source_png, output_icns):
    """Create ICNS file from source PNG using sips for resize."""
    tmpdir = tempfile.mkdtemp(prefix='icns_')
    try:
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
            resized_path = os.path.join(tmpdir, f'icon_{size}.png')
            # sips resize — preserves original format (RGB for dslogo1.png)
            subprocess.run(
                ['sips', '-z', str(size), str(size), source_png, '--out', resized_path],
                capture_output=True, check=True
            )
            with open(resized_path, 'rb') as f:
                png_data = f.read()
            entries.append((icon_type, png_data))
        
        total_size = 8
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
