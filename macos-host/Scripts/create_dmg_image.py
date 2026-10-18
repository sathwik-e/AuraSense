import os, sys, struct, stat, time, plistlib, zlib

BLOCK_SIZE = 4096
NODE_SIZE = 32768

def hfs_time(ts=None):
    if ts is None:
        ts = int(time.time())
    return int(ts) + 2082844800

def u16_str(s):
    raw = s.encode('utf-16-be')
    return struct.pack('>H', len(s)) + raw

def cat_key(parent_cnid, name):
    u = u16_str(name)
    return struct.pack('>HI', 4 + len(u), parent_cnid) + u

def hfs_fast_unicode_sort_key(name):
    # Apple HFS+ FastUnicodeCompare folds ASCII lowercase 'a'..'z' (0x61..0x7A)
    # to uppercase 'A'..'Z' (0x41..0x5A), so letters (65..90) sort BEFORE '_' (95).
    return [ord(c.upper()) for c in name]

def make_finder_background_alias(create_hfs_ts, bg_dir_cnid=16, bg_file_cnid=17):
    vol_name = "AuraSense"
    file_name = "dmg_background.png"
    vol_pas = bytes([len(vol_name)]) + vol_name.encode("ascii") + b"\x00" * (27 - len(vol_name))
    fn_pas = bytes([len(file_name)]) + file_name.encode("ascii") + b"\x00" * (63 - len(file_name))

    def tag_item(tag_id, raw_bytes):
        padded = raw_bytes + (b"\x00" if len(raw_bytes) % 2 == 1 else b"")
        return struct.pack(">hH", tag_id, len(raw_bytes)) + padded

    tags = (
        tag_item(0, b".background") +
        tag_item(2, b"AuraSense:.background:dmg_background.png") +
        tag_item(14, struct.pack(">H", len(file_name)) + file_name.encode("utf-16-be")) +
        tag_item(15, struct.pack(">H", len(vol_name)) + vol_name.encode("utf-16-be")) +
        tag_item(18, b"/.background/dmg_background.png") +
        tag_item(19, b"/Volumes/AuraSense") +
        struct.pack(">hH", -1, 0)
    )
    total_len = 150 + len(tags)
    header = struct.pack(
        ">IHHh28sI2sHI64sII4s4shhIH10s",
        0,
        total_len,
        2,
        0,
        vol_pas,
        create_hfs_ts,
        b"H+",
        5,
        bg_dir_cnid,
        fn_pas,
        bg_file_cnid,
        create_hfs_ts,
        b"\x00\x00\x00\x00",
        b"\x00\x00\x00\x00",
        1,
        1,
        0,
        0,
        b"\x00" * 10
    )
    return header + tags

def write_custom_ds_store(target_path, bg_dir_cnid=16, bg_file_cnid=17):
    bwsp = {
        'ContainerShowSidebar': False,
        'ShowPathbar': False,
        'ShowSidebar': False,
        'ShowStatusBar': False,
        'ShowTabView': False,
        'ShowToolbar': False,
        'WindowBounds': '{{200, 160}, {660, 468}}',
    }
    icvp = {
        'arrangeBy': 'none',
        'backgroundColorBlue': 0.05,
        'backgroundColorGreen': 0.02,
        'backgroundColorRed': 0.01,
        'backgroundType': 2,
        'backgroundImageAlias': make_finder_background_alias(hfs_time(), bg_dir_cnid, bg_file_cnid),
        'gridOffsetX': 0.0,
        'gridOffsetY': 0.0,
        'gridSpacing': 100.0,
        'iconSize': 96.0,
        'labelOnBottom': True,
        'showIconPreview': True,
        'showItemInfo': False,
        'textSize': 13.0,
        'viewOptionsVersion': 1,
    }
    bwsp_blob = plistlib.dumps(bwsp, fmt=plistlib.FMT_BINARY)
    icvp_blob = plistlib.dumps(icvp, fmt=plistlib.FMT_BINARY)

    def make_entry(filename, code, dtype, payload):
        fn_utf16 = filename.encode('utf-16-be')
        return struct.pack('>I', len(filename)) + fn_utf16 + code.encode('ascii') + dtype.encode('ascii') + payload

    def iloc_payload(x, y):
        return struct.pack('>I', 16) + struct.pack('>IIII', x, y, 0xFFFFFFFF, 0)

    entries = [
        ('.', 'bwsp', 'blob', struct.pack('>I', len(bwsp_blob)) + bwsp_blob),
        ('.', 'icvp', 'blob', struct.pack('>I', len(icvp_blob)) + icvp_blob),
        ('.', 'vSrn', 'long', struct.pack('>I', 1)),
        ('.VolumeIcon.icns', 'Iloc', 'blob', iloc_payload(900, 900)),
        ('.background', 'Iloc', 'blob', iloc_payload(900, 950)),
        ('Applications', 'Iloc', 'blob', iloc_payload(485, 220)),
        ('AuraSense.app', 'Iloc', 'blob', iloc_payload(175, 220)),
        ('Install AuraSense.app', 'Iloc', 'blob', iloc_payload(330, 345)),
    ]
    entries.sort(key=lambda item: (item[0].upper(), item[1]))
    raw_records = b''.join(make_entry(*e) for e in entries)

    leaf_block = bytearray(4096)
    struct.pack_into('>II', leaf_block, 0, 0, len(entries))
    leaf_block[8:8+len(raw_records)] = raw_records

    root_header = struct.pack('>IIIII', 2, 0, len(entries), 4096, 1) + b'\x00' * 12

    toc_block = bytearray(2048)
    struct.pack_into('>II', toc_block, 0, 3, 0)
    struct.pack_into('>III', toc_block, 8, 0x200b, 0x0025, 0x100c)
    pos = 8 + 3 * 4
    struct.pack_into('>I', toc_block, pos, 1)
    pos += 4
    toc_block[pos:pos+5] = b'\x04DSDB'
    pos += 5
    struct.pack_into('>I', toc_block, pos, 1)
    pos += 4
    for _ in range(32):
        struct.pack_into('>I', toc_block, pos, 0)
        pos += 4

    ds_file = bytearray(4 + 0x2800)
    struct.pack_into('>I', ds_file, 0, 1)
    struct.pack_into('>4sIII16s', ds_file, 4, b'Bud1', 0x2000, 2048, 0x2000, b'\x00' * 16)
    ds_file[4 + 0x20 : 4 + 0x20 + 32] = root_header
    ds_file[4 + 0x1000 : 4 + 0x1000 + 4096] = leaf_block
    ds_file[4 + 0x2000 : 4 + 0x2000 + 2048] = toc_block

    with open(target_path, 'wb') as f:
        f.write(ds_file)

class HFSPlusBuilder:
    def __init__(self, volume_name="AuraSense"):
        self.volume_name = volume_name
        self.next_cnid = 16
        self.items = []
        self.data_chunks = []
        self.current_data_block = 0
        self.data_region_start_block = 0
        self.ext_start_block = 2
        self.cat_start_block = 18

    def add_tree(self, root_dir):
        self._walk_dir(root_dir, 2, self.volume_name, is_root=True)

    def _alloc_data(self, data_bytes):
        if not data_bytes:
            return (0, 0, 0)
        bcount = (len(data_bytes) + BLOCK_SIZE - 1) // BLOCK_SIZE
        padded = data_bytes + b'\x00' * (bcount * BLOCK_SIZE - len(data_bytes))
        sblock = self.current_data_block
        self.current_data_block += bcount
        self.data_chunks.append(padded)
        return (len(data_bytes), sblock, bcount)

    def _walk_dir(self, fs_path, parent_cnid, name, is_root=False):
        st = os.lstat(fs_path)
        cnid = 2 if is_root else self.next_cnid
        if not is_root:
            self.next_cnid += 1

        children_names = sorted(os.listdir(fs_path), key=hfs_fast_unicode_sort_key)
        folder_item = {
            'type': 'folder',
            'cnid': cnid,
            'parent_cnid': 1 if is_root else parent_cnid,
            'name': name,
            'valence': len(children_names),
            'mtime': hfs_time(st.st_mtime),
            'mode': 0o040755,
            'custom_icon': is_root,
            'is_bundle': name.endswith('.app'),
        }
        self.items.append(folder_item)

        for child in children_names:
            cpath = os.path.join(fs_path, child)
            cst = os.lstat(cpath)
            if stat.S_ISLNK(cst.st_mode):
                target = os.readlink(cpath).encode('utf-8')
                f_cnid = self.next_cnid
                self.next_cnid += 1
                size, sblk, bcnt = self._alloc_data(target)
                self.items.append({
                    'type': 'file',
                    'cnid': f_cnid,
                    'parent_cnid': cnid,
                    'name': child,
                    'mtime': hfs_time(cst.st_mtime),
                    'mode': 0o120755,
                    'ftype': b'slnk',
                    'fcreator': b'rhap',
                    'fflags': 0,
                    'size': size,
                    'sblk': sblk,
                    'bcnt': bcnt,
                })
            elif stat.S_ISDIR(cst.st_mode):
                self._walk_dir(cpath, cnid, child, is_root=False)
            elif stat.S_ISREG(cst.st_mode):
                with open(cpath, 'rb') as f:
                    raw = f.read()
                f_cnid = self.next_cnid
                self.next_cnid += 1
                exec_bit = bool(cst.st_mode & 0o111)
                mode = 0o100755 if exec_bit else 0o100644
                fflags = 0x4000 if child.startswith('.') else 0
                size, sblk, bcnt = self._alloc_data(raw)
                self.items.append({
                    'type': 'file',
                    'cnid': f_cnid,
                    'parent_cnid': cnid,
                    'name': child,
                    'mtime': hfs_time(cst.st_mtime),
                    'mode': mode,
                    'ftype': b'\x00\x00\x00\x00',
                    'fcreator': b'\x00\x00\x00\x00',
                    'fflags': fflags,
                    'size': size,
                    'sblk': sblk,
                    'bcnt': bcnt,
                })

    def _pack_fork(self, logical_size, start_block, block_count):
        ext0 = struct.pack('>II', start_block if block_count > 0 else 0, block_count)
        ext_rest = b'\x00' * (7 * 8)
        return struct.pack('>QII', logical_size, BLOCK_SIZE * 4, block_count) + ext0 + ext_rest

    def _build_btree(self, records, max_key_len, is_catalog=True):
        records.sort(key=lambda r: r[0])

        def serialize_node(fLink, bLink, kind, height, rec_blobs):
            buf = bytearray(NODE_SIZE)
            struct.pack_into('>IIbbHH', buf, 0, fLink, bLink, kind, height, len(rec_blobs), 0)
            pos = 14
            offsets = [pos]
            for blob in rec_blobs:
                buf[pos:pos+len(blob)] = blob
                pos += len(blob)
                offsets.append(pos)
            for idx, off in enumerate(offsets):
                struct.pack_into('>H', buf, NODE_SIZE - 2 * (idx + 1), off)
            return bytes(buf)

        if not records:
            total_nodes = 2
            used_nodes = 1
            tree_depth = 0
            root_node = 0
            first_leaf = 0
            last_leaf = 0
        else:
            total_nodes = 3
            used_nodes = 2
            tree_depth = 1
            root_node = 1
            first_leaf = 1
            last_leaf = 1

        attrs = 0x00000006 if is_catalog else 0x00000002
        key_cmp = 0

        bt_header = struct.pack(
            '>HIIIIHHIIHIBBI',
            tree_depth,
            root_node,
            len(records),
            first_leaf,
            last_leaf,
            NODE_SIZE,
            max_key_len,
            total_nodes,
            total_nodes - used_nodes,
            0,
            NODE_SIZE * 2,
            0,
            key_cmp,
            attrs,
        ) + (b'\x00' * 64)

        user_rec = b'\x00' * 128
        map_rec = bytearray(NODE_SIZE - 256)
        for i in range(used_nodes):
            map_rec[i // 8] |= (0x80 >> (i % 8))

        nodes_out = [serialize_node(0, 0, 1, 0, [bt_header, user_rec, bytes(map_rec)])]

        if records:
            blobs = []
            for _, kbytes, vbytes in records:
                if len(kbytes) % 2 == 1:
                    kbytes += b'\x00'
                rec = kbytes + vbytes
                if len(rec) % 2 == 1:
                    rec += b'\x00'
                blobs.append(rec)
            nodes_out.append(serialize_node(0, 0, -1, 1, blobs))

        nodes_out.append(b'\x00' * NODE_SIZE)
        return b''.join(nodes_out)

    def build_volume_bytes(self):
        for _ in range(2):
            cat_records = []
            for item in self.items:
                p_cnid = item['parent_cnid']
                cnid = item['cnid']
                name = item['name']
                mtime = item['mtime']
                # HFS+ FastUnicodeCompare case-folding sort order (uppercase folds letters to 65..90 < '_' 95)
                name_sort = hfs_fast_unicode_sort_key(name)
                kbytes = cat_key(p_cnid, name)

                if item['type'] == 'folder':
                    finfo = bytearray(16)
                    if item.get('custom_icon'):
                        struct.pack_into('>H', finfo, 8, 0x0400)
                    elif item.get('is_bundle'):
                        struct.pack_into('>H', finfo, 8, 0x2000)
                    bsd = struct.pack('>IIBBHI', 99, 99, 0, 0, item['mode'], 0)
                    val = struct.pack(
                        '>hHIIIIIII16s16s16sII',
                        0x0001,
                        0x0002,
                        item['valence'],
                        cnid,
                        mtime, mtime, mtime, mtime, 0,
                        bsd,
                        bytes(finfo),
                        b'\x00' * 16,
                        0, 0
                    )
                    cat_records.append(((p_cnid, name_sort), kbytes, val))

                    tkbytes = cat_key(cnid, "")
                    tval = struct.pack('>hhI', 0x0003, 0, p_cnid) + u16_str(name)
                    cat_records.append(((cnid, []), tkbytes, tval))
                else:
                    finfo = bytearray(16)
                    finfo[0:4] = item['ftype']
                    finfo[4:8] = item['fcreator']
                    struct.pack_into('>H', finfo, 8, item['fflags'])
                    bsd = struct.pack('>IIBBHI', 99, 99, 0, 0, item['mode'], 1)
                    abs_start_blk = (self.data_region_start_block + item['sblk']) if item['bcnt'] > 0 else 0
                    dfork = self._pack_fork(item['size'], abs_start_blk, item['bcnt'])
                    rfork = self._pack_fork(0, 0, 0)
                    val = struct.pack(
                        '>hHIIIIIII16s16s16sII',
                        0x0002,
                        0x0002,
                        0,
                        cnid,
                        mtime, mtime, mtime, mtime, 0,
                        bsd,
                        bytes(finfo),
                        b'\x00' * 16,
                        0, 0
                    ) + dfork + rfork
                    cat_records.append(((p_cnid, name_sort), kbytes, val))

                    tkbytes = cat_key(cnid, "")
                    tval = struct.pack('>hhI', 0x0004, 0, p_cnid) + u16_str(name)
                    cat_records.append(((cnid, []), tkbytes, tval))

            cat_btree = self._build_btree(cat_records, 516, is_catalog=True)
            ext_btree = self._build_btree([], 10, is_catalog=False)

            cat_blocks = len(cat_btree) // BLOCK_SIZE
            ext_blocks = len(ext_btree) // BLOCK_SIZE
            self.ext_start_block = 2
            self.cat_start_block = 2 + ext_blocks
            self.data_region_start_block = self.cat_start_block + cat_blocks

        total_used_blocks = self.data_region_start_block + self.current_data_block
        total_blocks = max(total_used_blocks + 64, 2100)
        free_blocks = total_blocks - total_used_blocks - 1

        b0 = bytearray(BLOCK_SIZE)
        now = hfs_time()
        alloc_fork = self._pack_fork(BLOCK_SIZE, 1, 1)
        ext_fork = self._pack_fork(len(ext_btree), self.ext_start_block, ext_blocks)
        cat_fork = self._pack_fork(len(cat_btree), self.cat_start_block, cat_blocks)
        attr_fork = self._pack_fork(0, 0, 0)
        start_fork = self._pack_fork(0, 0, 0)

        num_files = sum(1 for x in self.items if x['type'] == 'file')
        num_folders = sum(1 for x in self.items if x['type'] == 'folder') - 1

        vh = struct.pack(
            '>2sHIIIIIIIIIIIIIIIIIQ32s',
            b'H+',
            4,
            0x00000100,
            0x4846532B,
            0,
            now, now, 0, now,
            num_files,
            num_folders,
            BLOCK_SIZE,
            total_blocks,
            free_blocks,
            self.data_region_start_block,
            BLOCK_SIZE * 4,
            BLOCK_SIZE * 4,
            self.next_cnid,
            1,
            1,
            b'\x00' * 32
        ) + alloc_fork + ext_fork + cat_fork + attr_fork + start_fork
        b0[1024:1024+512] = vh

        b1 = bytearray(BLOCK_SIZE)
        for blk in range(total_used_blocks):
            b1[blk // 8] |= (0x80 >> (blk % 8))
        last_blk = total_blocks - 1
        b1[last_blk // 8] |= (0x80 >> (last_blk % 8))

        pad_free_blocks = total_blocks - total_used_blocks - 1
        alt_b = bytearray(BLOCK_SIZE)
        alt_b[BLOCK_SIZE - 1024 : BLOCK_SIZE - 1024 + 512] = vh

        parts = [bytes(b0), bytes(b1), ext_btree, cat_btree] + self.data_chunks + [b'\x00' * (pad_free_blocks * BLOCK_SIZE), bytes(alt_b)]
        return b''.join(parts)

if __name__ == '__main__':
    staging = sys.argv[1]
    out_dmg = sys.argv[2]
    write_custom_ds_store(os.path.join(staging, '.DS_Store'), bg_dir_cnid=16, bg_file_cnid=17)
    builder = HFSPlusBuilder("AuraSense")
    builder.add_tree(staging)
    vol_bytes = builder.build_volume_bytes()
    with open(out_dmg, 'wb') as f:
        f.write(vol_bytes)
    print(f"Created HFS+ DMG image: {out_dmg} ({len(vol_bytes)} bytes)")
