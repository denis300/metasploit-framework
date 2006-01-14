#!/usr/bin/env ruby

module Rex
module Arch

#
# everything here is mostly stole from vlad's perl x86 stuff
#

module X86

	#
	# Register number constants
	#
	EAX = AL = AX = ES = 0
	ECX = CL = CX = CS = 1
	EDX = DL = DX = SS = 2
	EBX = BL = BX = DS = 3
	ESP = AH = SP = FS = 4
	EBP = CH = BP = GS = 5
	ESI = DH = SI =      6
	EDI = BH = DI =      7

	REG_NAMES32 = [ 'eax', 'ecx', 'edx', 'ebx', 
	                'esp', 'ebp', 'esi', 'edi' ] # :nodoc:

	#
	# This method adds/subs a packed long integer
	#
	def self.dword_adjust(dword, amount=0)
		[dword.unpack('V')[0] + amount].pack('V')
	end
	
	#
	# This method returns the opcodes that compose a tag-based search routine
	#
	def self.searcher(tag)
		"\xbe" + dword_adjust(tag,-1)+  # mov esi, Tag - 1
		"\x46" +                        # inc esi
		"\x47" +                        # inc edi (end_search:)
		"\x39\x37" +                    # cmp [edi],esi
		"\x75\xfb" +                    # jnz 0xa (end_search)
		"\x46" +                        # inc esi
		"\x4f" +                        # dec edi (start_search:)
		"\x39\x77\xfc" +                # cmp [edi-0x4],esi
		"\x75\xfa" +                    # jnz 0x10 (start_search)
		"\xff\xe7"                      # jmp edi	
	end


	
	#
	# This method returns the opcodes that compose a short jump instruction to
	# the supplied relative offset.
	#
	def self.jmp_short(addr)
		"\xeb" + pack_lsb(rel_number(addr, -2))
	end

	#
	# This method returns the opcodes that compose a relative call instruction
	# to the address specified.
	#
	def self.call(addr)
		"\xe8" + pack_dword(rel_number(addr, -5))
	end

	#
	# This method returns a number offset to the supplied string.
	#
	def self.rel_number(num, delta = 0)
		s = num.to_s

		case s[0, 2]
			when '$+'
				num = s[2 .. -1].to_i
			when '$-'
				num = -1 * s[2 .. -1].to_i
			when '0x'
				num = s.hex
			else
				delta = 0
		end

		return num + delta
	end

	#
	# This method returns the number associated with a named register.
	#
	def self.reg_number(str)
		return self.const_get(str.upcase)
	end

	#
	# This method returns the register named associated with a given register
	# number.
	#
	def self.reg_name32(num)
		_check_reg(num)
		return REG_NAMES32[num].dup
	end

	#
	# This method generates the encoded effective value for a register.
	#
	def self.encode_effective(shift, dst)
		return (0xc0 | (shift << 3) | dst)
	end

	#
	# This method generates the mod r/m character for a source and destination
	# register.
	#
	def self.encode_modrm(dst, src)
		_check_reg(dst, src)
		return (0xc0 | src | dst << 3).chr
	end

	#
	# This method generates a push byte instruction.
	#
	def self.push_byte(byte)
		# push byte will sign extend...
		if byte < 128 && byte >= -128
			return "\x6a" + (byte & 0xff).chr
		end
		raise ::ArgumentError, "Can only take signed byte values!", caller()
	end

	#
	# This method generates a push dword instruction.
	#
	def self.push_dword(val)
		return "\x68" + [ val ].pack('V') 
	end

	#
	# This method generates a pop dword instruction into a register.
	#
	def self.pop_dword(dst)
		_check_reg(dst)
		return (0x58 | dst).chr
	end

	#
	# This method generates an instruction that clears the supplied register in
	# a manner that attempts to avoid bad characters, if supplied.
	#
	def self.clear(reg, badchars = '')
		_check_reg(reg)
		return set(reg, 0, badchars)
	end

	#
	# This method generates the opcodes that set the low byte of a given
	# register to the supplied value.
	#
	def self.mov_byte(reg, val)
		_check_reg(reg)
		# chr will raise RangeError if val not between 0 .. 255
		return (0xb0 | reg).chr + val.chr
	end

	#
	# This method generates the opcodes that set the low word of a given
	# register to the supplied value.
	#
	def self.mov_word(reg, val)
		_check_reg(reg)
		if val < 0 || val > 0xffff
			raise RangeError, "Can only take unsigned word values!", caller()
		end
		return "\x66" + (0xb8 | reg).chr + [ val ].pack('v')
	end

	#
	# This method generates the opcodes that set the a register to the
	# supplied value.
	#
	def self.mov_dword(reg, val)
		_check_reg(reg)
		return (0xb8 | reg).chr + [ val ].pack('V')
	end

	#
	# This method is a general way of setting a register to a value.  Depending
	# on the value supplied, different sets of instructions may be used.
	#
	# TODO: Make this moderatly intelligent so it chain instructions by itself
        #   (ie. xor eax, eax + mov al, 4 + xchg ah, al)
	def self.set(dst, val, badchars = '')
		_check_reg(dst)

		# If the value is 0 try xor/sub dst, dst (2 bytes)
		if(val == 0)
			opcodes = Rex::Text.remove_badchars("\x29\x2b\x31\x33", badchars)
			if !opcodes.empty?
				return opcodes[rand(opcodes.length)].chr + encode_modrm(dst, dst)
			end
# TODO: SHL/SHR
# TODO: AND 
		end

		# try push BYTE val; pop dst (3 bytes)
		begin
			return _check_badchars(push_byte(val) + pop_dword(dst), badchars)
		rescue ::ArgumentError, RuntimeError, RangeError
		end

		# try clear dst, mov BYTE dst (4 bytes)
		begin
			break if val == 0
			return _check_badchars(clear(dst, badchars) + mov_byte(dst, val), badchars)
		rescue ::ArgumentError, RuntimeError, RangeError
		end

		# try mov DWORD dst (5 bytes)
		begin
			return _check_badchars(mov_dword(dst, val), badchars)
		rescue ::ArgumentError, RuntimeError, RangeError
		end

		# try push DWORD, pop dst (6 bytes)
		begin
			return _check_badchars(push_dword(val) + pop_dword(dst), badchars)
		rescue ::ArgumentError, RuntimeError, RangeError
		end

		# try clear dst, mov WORD dst (6 bytes)
		begin
			break if val == 0
			return _check_badchars(clear(dst, badchars) + mov_word(dst, val), badchars)
		rescue ::ArgumentError, RuntimeError, RangeError
		end

		raise RuntimeError, "No valid set instruction could be created!", caller()
	end

	#
	# Builds a subtraction instruction using the supplied operand
	# and register.
	#
	def self.sub(val, reg, badchars = '', add = false, adjust = false, bits = 0)
		opcodes = []
		shift   = (add == true) ? 0 : 5

		if (bits <= 8 and val >= -0x7f and val <= 0x7f)
			opcodes << 
				((adjust) ? '' : clear(reg, badchars)) + 
				"\x83" + 
				[ encode_effective(shift, reg) ].pack('C') +
				[ val.to_i ].pack('C')
		end

		if (bits <= 16 and val >= -0xffff and val <= 0)
			opcodes << 
				((adjust) ? '' : clear(reg, badchars)) + 
				"\x66\x81" + 
				[ encode_effective(shift, reg) ].pack('C') +
				[ val.to_i ].pack('v')
		end
			
		opcodes << 
			((adjust) ? '' : clear(reg, badchars)) + 
			"\x81" + 
			[ encode_effective(shift, reg) ].pack('C') +
			[ val.to_i ].pack('V')

		# Search for a compatible opcode
		opcodes.each { |op|
			begin 
				_check_badchars(op, badchars)
			rescue
				next
			end

			return op
		}

		if opcodes.empty?
			raise RuntimeError, "Could not find a usable opcode", caller()
		end
	end

	#
	# This method generates the opcodes equivalent to subtracting with a
	# negative value from a given register.
	#
	def self.add(val, reg, badchars = '', adjust = false, bits = 0)
		sub(val, reg, badchars, true, adjust, bits)
	end

	#
	# This method wrappers packing an integer as a little-endian buffer.
	#
	def self.pack_dword(num)
		[num].pack('V')
	end

	#
	# This method returns the least significant byte of a packed dword.
	#
	def self.pack_lsb(num)
		pack_dword(num)[0,1]
	end

	#
	# This method adjusts the value of the ESP register by a given amount.
	#
	def self.adjust_reg(reg, adjustment)
		if (adjustment > 0)
			sub(adjustment, reg, '', false, false, 32)
		else
			add(adjustment, reg, '', true, 32)
		end
	end

	def self._check_reg(*regs) # :nodoc:
		regs.each { |reg|
			if reg > 7 || reg < 0
				raise ArgumentError, "Invalid register #{reg}", caller()
			end
		}
		return nil
	end

	def self._check_badchars(data, badchars) # :nodoc:
		idx = Rex::Text.badchar_index(data, badchars)
		if idx
			raise RuntimeError, "Bad character at #{idx}", caller()
		end
		return data
	end

end

end end
