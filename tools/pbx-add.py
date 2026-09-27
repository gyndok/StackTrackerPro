#!/usr/bin/env python3
"""Wire a Swift source into StackTrackerPro.xcodeproj (explicit file refs, objectVersion 77).

usage: tools/pbx-add.py <NewFile.swift> <AnchorFile.swift> <REF_ID> <BUILD_ID>

AnchorFile must already be wired and live in the SAME group as the new file.
Inserts four lines right after the anchor's: PBXBuildFile, PBXFileReference,
group child, Sources build-phase entry. IDs are 24 hex chars; never reuse one.
"""
import re
import sys

if len(sys.argv) != 5:
    sys.exit(__doc__)
name, anchor, ref_id, build_id = sys.argv[1:5]
path = "StackTrackerPro.xcodeproj/project.pbxproj"
s = open(path).read()
if ref_id in s or build_id in s:
    sys.exit(f"ID already used: {ref_id} / {build_id}")

m = re.search(r"\t\t(\w+) /\* %s \*/ = \{isa = PBXFileReference" % re.escape(anchor), s)
if not m:
    sys.exit(f"anchor file reference not found: {anchor}")
anchor_ref = m.group(1)
m = re.search(r"\t\t(\w+) /\* %s in Sources \*/ = \{isa = PBXBuildFile" % re.escape(anchor), s)
if not m:
    sys.exit(f"anchor build file not found: {anchor}")
anchor_build = m.group(1)


def insert_after(text, needle, new_line):
    i = text.index(needle)
    j = text.index("\n", i) + 1
    return text[:j] + new_line + text[j:]


s = insert_after(s, f"{anchor_build} /* {anchor} in Sources */ = {{isa = PBXBuildFile",
                 f"\t\t{build_id} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {ref_id} /* {name} */; }};\n")
s = insert_after(s, f"{anchor_ref} /* {anchor} */ = {{isa = PBXFileReference",
                 f"\t\t{ref_id} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {name}; sourceTree = \"<group>\"; }};\n")
s = insert_after(s, f"\t\t\t\t{anchor_ref} /* {anchor} */,",
                 f"\t\t\t\t{ref_id} /* {name} */,\n")
s = insert_after(s, f"\t\t\t\t{anchor_build} /* {anchor} in Sources */,",
                 f"\t\t\t\t{build_id} /* {name} in Sources */,\n")
open(path, "w").write(s)
print(f"wired {name} after {anchor}")
