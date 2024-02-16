//+private file
package back

import "core:os"
import "core:runtime"
import "core:slice"
import "core:sys/linux"
import "core:strings"

// TODO: remove these dependencies.
import "core:fmt"
import "core:log"

import "elf"
import "dwarf"

PROGRAM: string

@(init)
program_init :: proc() {
	// TODO: don't do this in init, handle bigger paths.
	prog: [1024]byte
	read, err := linux.readlink("/proc/self/exe", prog[:])
	assert(read != 1024 && err == .NONE, "reading /proc/self/exe failed")
	PROGRAM = strings.clone_from(prog[:read])
}

@(private="package")
_Trace_Entry :: rawptr

@(private="package")
_trace :: proc(buf: Trace) -> (n: int) {
	ok: bool
	n, ok = backtrace(buf)
	if !ok { n = 0 }
	fmt.println(buf)
	return
}

@(private="package")
_lines_destroy :: proc(msgs: []Line) {
	for msg in msgs {
		if msg.location != "??" do delete(msg.location)
		if msg.symbol   != "??" do delete(msg.symbol)
	}
	delete(msgs)
}

@(private="package")
_lines :: proc(bt: Trace) -> (out: []Line, err: Lines_Error) {
	out = make([]Line, len(bt))

	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD(ignore=context.allocator==context.temp_allocator)

	fh, errno := os.open(PROGRAM, os.O_RDONLY)
	assert(errno == os.ERROR_NONE)
	defer os.close(fh)

	file: elf.File
	eerr := elf.file_init(&file, os.stream_from_handle(fh))
	assert(eerr == nil)

	Entry :: struct {
		table: u32,
		name:  u32,
		value: uintptr,
		size:  uintptr,
	}

	tables  := make([dynamic]elf.Symbol_Table, context.temp_allocator)
	symbols := make([dynamic]Entry,            context.temp_allocator)

	idx: int
	for hdr in elf.iter_section_headers(&file, &idx, &eerr) {
		#partial switch hdr.type {
		case .SYMTAB, .DYNSYM, .SUNW_LDYNSYM:
			strtbl: elf.String_Table
			strtbl.file = &file

			strtbl.hdr, eerr = elf.get_section_header(&file, int(hdr.link))
			assert(eerr == nil)

			symtab: elf.Symbol_Table
			symtab.str_table = strtbl
			symtab.hdr = hdr

			assert(symtab.hdr.entsize > 0)
			assert(symtab.hdr.size % symtab.hdr.entsize == 0)

			append(&tables, symtab)
			table := len(tables)-1

			idx: int
			for sym in elf.iter_symbols(&symtab, &idx, &eerr) {
				append(&symbols, Entry{
					table = u32(table),
					name  = sym.name,
					value = uintptr(sym.value),
					size  = uintptr(sym.size),
				})
			}
		}
	}
	assert(eerr == nil)

	slice.sort_by(symbols[:], proc(a, b: Entry) -> bool {
		return a.value < b.value
	})

	for &line, i in out {
		// TODO: this API is weird as fuck.
		idx, _ := slice.binary_search_by(symbols[:], Entry{value = uintptr(bt[i])}, proc(a, b: Entry) -> slice.Ordering {
			return slice.cmp_proc(uintptr)(a.value, b.value)
		})

		line = Line {
			location = "??",
			symbol   = "??",
		}

		if idx <= 0 {
			continue
		}

		symbol := symbols[idx-1]
		offset := uintptr(bt[i]) - symbol.value
		if uintptr(bt[i]) > symbol.value + symbol.size {
			continue
		}

		tbl := tables[symbol.table]

		// TODO: make this one allocation.
		line.symbol, eerr = elf.get_string(&tbl.str_table, int(symbol.name), context.temp_allocator)
		line.symbol = fmt.aprintf("%v +%v", line.symbol, offset)

		assert(eerr == nil)
	}

	if !elf.has_dwarf_info(&file) {
		return
	}

	info: dwarf.Info
	info, eerr = elf.dwarf_info(&file, false, false)
	assert(eerr == nil)

	off: u64
	derr: dwarf.Error
	for cu in dwarf.iter_CUs(info, &off, &derr) {
		lp, lp_err := dwarf.line_program_for_CU(info, cu, context.temp_allocator)
		assert(lp_err == nil)

		if rlp, has_lp := lp.?; has_lp {
			entries, decode_err := dwarf.decode_line_program(info, cu, &rlp, context.temp_allocator)
			assert(decode_err == nil)

			for _address, i in bt {
				address := uintptr(_address)
				_prev_state: Maybe(dwarf.Line_State)
				for entry in entries {
					state, has_state := entry.state.?
					if !has_state {
						continue
					}

					if prev_state, has_prev_state := _prev_state.?; has_prev_state {
						if uintptr(prev_state.address) <= address && address < uintptr(state.address) {
							file := rlp.hdr.file_entries[prev_state.file - 1]
							line := prev_state.line
							col  := prev_state.column
							if file.dir_index == 0 {
								out[i].location = fmt.aprintf("%s(%i:%i)", file.name, line, col)
							} else {
								directory := rlp.hdr.include_directories[file.dir_index - 1]
								out[i].location = fmt.aprintf("%s/%s(%i:%i)", directory, file.name, line, col)
							}
							break
						}
					}

					if state.end_sequence {
						_prev_state = nil
					} else {
						_prev_state = state
					}
				}
			}
		}
	}

	return
}

backtrace :: proc(buf: Trace) -> (n: int, ok: bool) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	fh, errno := os.open(PROGRAM, os.O_RDONLY)
	if errno != os.ERROR_NONE {
		log.errorf("back.trace: opening elf file %q, errno: %i", PROGRAM, errno)
		return
	}
	defer os.close(fh)

	file: elf.File
	elf_err := elf.file_init(&file, os.stream_from_handle(fh)) // Allocates.
	if elf_err != nil {
		log.errorf("back.trace: elf file parsing init error: %v", elf_err)
		return
	}

	if !elf.has_unwind_info(&file) {
		log.warn("back.trace: elf file has no unwind info")
		return
	}

	info, info_err := elf.dwarf_info(&file, false, false)
	if info_err != nil {
		log.errorf("back.trace: dwarf info construction error: %v", info_err)
		return
	}

	regs: dwarf.Registers
	dwarf.registers_current(&regs)

	u: dwarf.Unwinder
	dwarf.unwinder_init(&u, &info, regs)

	for n < len(buf) {
		cf := dwarf.unwinder_next(&u) or_break // Allocates.
		if cf.pc == 0 { break }
		buf[n] = rawptr(uintptr(cf.pc))
		n += 1
	}

	ok = true
	return
}
