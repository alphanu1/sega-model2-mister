// license:BSD-3-Clause
// copyright-holders:Andreas Naive, Olivier Galibert, David Haywood
//
// sim/prot/m2_5881_ref.h -- MAME 0.289's sega/315-5881_crypt.cpp (the 315-5881
// decryption / decompression chip), standalone, as the oracle for the Model 2A
// core's Zero Gunner (study R862). Generated from MAME's file: its functions
// do_decrypt .. set_subkey and everything from fn1_sboxes to the end, verbatim
// but for the class name; the device framework is replaced by the small
// interface below (addrlo_w / addrhi_w / subkey_le_w / decrypt_le_r, as
// MAME's iomap_le, and m_read, model2.cpp's crypt_read_callback). The BSD-3
// terms are in THIRD_PARTY.md.
#pragma once
#include <cstdint>
#include <cstring>
#include <cassert>
#include <functional>
#include <memory>

struct M2_5881Ref {
  static int BIT(uint32_t x, int n) { return (x >> n) & 1; }
  template <int N> static uint32_t bitswap(uint32_t v, int b15, int b14, int b13, int b12, int b11, int b10, int b9, int b8,
                                           int b7, int b6, int b5, int b4, int b3, int b2, int b1, int b0) {
    const int b[16] = {b0, b1, b2, b3, b4, b5, b6, b7, b8, b9, b10, b11, b12, b13, b14, b15};
    uint32_t r = 0;
    for (int i = 0; i < 16; ++i) r |= uint32_t(BIT(v, b[i])) << i;
    return r;
  }
  std::function<uint16_t(uint32_t)> m_read;
  uint32_t key = 0;
  bool first_read = false;
  enum { BUFFER_SIZE = 2, LINE_SIZE = 512, FLAG_COMPRESSED = 0x20000 };
  std::unique_ptr<uint8_t[]> buffer{new uint8_t[BUFFER_SIZE]()};
  std::unique_ptr<uint8_t[]> line_buffer{new uint8_t[LINE_SIZE]()};
  std::unique_ptr<uint8_t[]> line_buffer_prev{new uint8_t[LINE_SIZE]()};
  uint32_t prot_cur_address = 0;
  uint16_t subkey = 0, dec_hist = 0;
  uint32_t dec_header = 0;
  bool enc_ready = 0;
  int buffer_pos = 0, line_buffer_pos = 0, line_buffer_size = 0, buffer_bit = 0, buffer_bit2 = 0;
  uint8_t buffer2[2]{};
  uint16_t buffer2a = 0;
  int block_size = 0, block_pos = 0, block_numlines = 0, done_compression = 0;
  struct sbox { uint8_t table[64]; int inputs[6]; int outputs[2]; };
  static const sbox fn1_sboxes[4][4];
  static const sbox fn2_sboxes[4][4];
  static const int FN1GK = 38;
  static const int FN2GK = 32;
  static const int fn1_game_key_scheduling[FN1GK][2];
  static const int fn2_game_key_scheduling[FN2GK][2];
  static const int fn1_sequence_key_scheduling[20][2];
  static const int fn2_sequence_key_scheduling[16];
  static const int fn2_middle_result_scheduling[16];
  static const uint8_t trees[9][2][32];

  // device_reset
  void reset() {
    std::memset(buffer.get(), 0, BUFFER_SIZE); std::memset(line_buffer.get(), 0, LINE_SIZE);
    std::memset(line_buffer_prev.get(), 0, LINE_SIZE);
    prot_cur_address = 0; subkey = 0; dec_hist = 0; dec_header = 0; enc_ready = false; first_read = false;
    buffer_pos = 0; line_buffer_pos = 0; line_buffer_size = 0; buffer_bit = 0;
  }
  // iomap_le
  uint16_t ready_r() { return 0; }
  void addrlo_w(uint16_t data) { set_addr_low(data & 0xffff); first_read = true; }
  void addrhi_w(uint16_t) { set_addr_high(0); first_read = true; }
  void subkey_le_w(uint16_t data) { set_subkey(data & 0xffff); }
  uint16_t decrypt_be_r() {
    if (first_read) { first_read = false; return 0; }
    uint8_t *base; return do_decrypt(base);
  }
  uint16_t decrypt_le_r() { uint16_t r = decrypt_be_r(); return uint16_t(((r & 0xff00) >> 8) | ((r & 0x00ff) << 8)); }

  uint16_t do_decrypt(uint8_t *&base);
  void set_addr_low(uint16_t data);
  void set_addr_high(uint16_t data);
  void set_subkey(uint16_t data);
  int feistel_function(int input, const struct sbox *sboxes, uint32_t subkeys);
  uint16_t block_decrypt(uint32_t game_key, uint16_t sequence_key, uint16_t counter, uint16_t data);
  uint16_t get_decrypted_16();
  int get_compressed_bit();
  void enc_start();
  void enc_fill();
  void line_fill();
};

inline uint16_t M2_5881Ref::do_decrypt(uint8_t *&base)
{
	if(!enc_ready)
		enc_start();
	if(dec_header & FLAG_COMPRESSED) {
		if (line_buffer_pos == line_buffer_size) // if there's no data left to read..
		{
			if (done_compression == 1)
				enc_start();

			line_fill();
		}
		base = line_buffer.get() + line_buffer_pos;
		line_buffer_pos += 2;
	} else {
		if(buffer_pos == BUFFER_SIZE)
			enc_fill();

		base = buffer.get() + buffer_pos;
		buffer_pos += 2;
	}

	return (base[0] << 8) | base[1];
}

inline void M2_5881Ref::set_addr_low(uint16_t data)
{
	prot_cur_address = (prot_cur_address & 0xffff0000) | data;
	enc_ready = false;
}

inline void M2_5881Ref::set_addr_high(uint16_t data)
{
	prot_cur_address = (prot_cur_address & 0x0000ffff) | (data << 16);
	enc_ready = false;

	buffer_bit = 7;
	buffer_bit2 = 15;
}

inline void M2_5881Ref::set_subkey(uint16_t data)
{
	subkey = data;
	enc_ready = false;
}


const M2_5881Ref::sbox M2_5881Ref::fn1_sboxes[4][4] = {
	{   // 1st round
		{
			{
				0,3,2,2,1,3,1,2,3,2,1,2,1,2,3,1,3,2,2,0,2,1,3,0,0,3,2,3,2,1,2,0,
				2,3,1,1,2,2,1,1,1,0,2,3,3,0,2,1,1,1,1,1,3,0,3,2,1,0,1,2,0,3,1,3,
			},
			{3,4,5,7,-1,-1},
			{0,4}
		},

		{
			{
				2,2,2,0,3,3,0,1,2,2,3,2,3,0,2,2,1,1,0,3,3,2,0,2,0,1,0,1,2,3,1,1,
				0,1,3,3,1,3,3,1,2,3,2,0,0,0,2,2,0,3,1,3,0,3,2,2,0,3,0,3,1,1,0,2,
			},
			{0,1,2,5,6,7},
			{1,6}
		},

		{
			{
				0,1,3,0,3,1,1,1,1,2,3,1,3,0,2,3,3,2,0,2,1,1,2,1,1,3,1,0,0,2,0,1,
				1,3,1,0,0,3,2,3,2,0,3,3,0,0,0,0,1,2,3,3,2,0,3,2,1,0,0,0,2,2,3,3,
			},
			{0,2,5,6,7,-1},
			{2,3}
		},

		{
			{
				3,2,1,2,1,2,3,2,0,3,2,2,3,1,3,3,0,2,3,0,3,3,2,1,1,1,2,0,2,2,0,1,
				1,3,3,0,0,3,0,3,0,2,1,3,2,1,0,0,0,1,1,2,0,1,0,0,0,1,3,3,2,0,3,3,
			},
			{1,2,3,4,6,7},
			{5,7}
		},
	},
	{   // 2nd round
		{
			{
				3,3,1,2,0,0,2,2,2,1,2,1,3,1,1,3,3,0,0,3,0,3,3,2,1,1,3,2,3,2,1,3,
				2,3,0,1,3,2,0,1,2,1,3,1,2,2,3,3,3,1,2,2,0,3,1,2,2,1,3,0,3,0,1,3,
			},
			{0,1,3,4,5,7},
			{0,4}
		},

		{
			{
				2,0,1,0,0,3,2,0,3,3,1,2,1,3,0,2,0,2,0,0,0,2,3,1,3,1,1,2,3,0,3,0,
				3,0,2,0,0,2,2,1,0,2,3,3,1,3,1,0,1,3,3,0,0,1,3,1,0,2,0,3,2,1,0,1,
			},
			{0,1,3,4,6,-1},
			{1,5}
		},

		{
			{
				2,2,2,3,1,1,0,1,3,3,1,1,2,2,2,0,0,3,2,3,3,0,2,1,2,2,3,0,1,3,0,0,
				3,2,0,3,2,0,1,0,0,1,2,2,3,3,0,2,2,1,3,1,1,1,1,2,0,3,1,0,0,2,3,2,
			},
			{1,2,5,6,7,6},
			{2,7}
		},

		{
			{
				0,1,3,3,3,1,3,3,1,0,2,0,2,0,0,3,1,2,1,3,1,2,3,2,2,0,1,3,0,3,3,3,
				0,0,0,2,1,1,2,3,2,2,3,1,1,2,0,2,0,2,1,3,1,1,3,3,1,1,3,0,2,3,0,0,
			},
			{2,3,4,5,6,7},
			{3,6}
		},
	},
	{   // 3rd round
		{
			{
				0,0,1,0,1,0,0,3,2,0,0,3,0,1,0,2,0,3,0,0,2,0,3,2,2,1,3,2,2,1,1,2,
				0,0,0,3,0,1,1,0,0,2,1,0,3,1,2,2,2,0,3,1,3,0,1,2,2,1,1,1,0,2,3,1,
			},
			{1,2,3,4,5,7},
			{0,5}
		},

		{
			{
				1,2,1,0,3,1,1,2,0,0,2,3,2,3,1,3,2,0,3,2,2,3,1,1,1,1,0,3,2,0,0,1,
				1,0,0,1,3,1,2,3,0,0,2,3,3,0,1,0,0,2,3,0,1,2,0,1,3,3,3,1,2,0,2,1,
			},
			{0,2,4,5,6,7},
			{1,6}
		},

		{
			{
				0,3,0,2,1,2,0,0,1,1,0,0,3,1,1,0,0,3,0,0,2,3,3,2,3,1,2,0,0,2,3,0,
				// unused?
				255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,
			},
			{0,2,4,6,7,-1},
			{2,3}
		},

		{
			{
				0,0,1,0,0,1,0,2,3,3,0,3,3,2,3,0,2,2,2,0,3,2,0,3,1,0,0,3,3,0,0,0,
				2,2,1,0,2,0,3,2,0,0,3,1,3,3,0,0,2,1,1,2,1,0,1,1,0,3,1,2,0,2,0,3,
			},
			{0,1,2,3,6,-1},
			{4,7}
		},
	},
	{   // 4th round
		{
			{
				0,3,3,3,3,3,2,0,0,1,2,0,2,2,2,2,1,1,0,2,2,1,3,2,3,2,0,1,2,3,2,1,
				3,2,2,3,1,0,1,0,0,2,0,1,2,1,2,3,1,2,1,1,2,2,1,0,1,3,2,3,2,0,3,1,
			},
			{0,1,3,4,5,6},
			{0,5}
		},

		{
			{
				0,3,0,0,2,0,3,1,1,1,2,2,2,1,3,1,2,2,1,3,2,2,3,3,0,3,1,0,3,2,0,1,
				3,0,2,0,1,0,2,1,3,3,1,2,2,0,2,3,3,2,3,0,1,1,3,3,0,2,1,3,0,2,2,3,
			},
			{0,1,2,3,5,7},
			{1,7}
		},

		{
			{
				0,1,2,3,3,3,3,1,2,0,2,3,2,1,0,1,2,2,1,2,0,3,2,0,1,1,0,1,3,1,3,1,
				3,1,0,0,1,0,0,0,0,1,2,2,1,1,3,3,1,2,3,3,3,2,3,0,2,2,1,3,3,0,2,0,
			},
			{2,3,4,5,6,7},
			{2,3}
		},

		{
			{
				0,2,1,1,3,2,0,3,1,0,1,0,3,2,1,1,2,2,0,3,1,0,1,2,2,2,3,3,0,0,0,0,
				1,2,1,0,2,1,2,2,2,3,2,3,0,1,3,0,0,1,3,0,0,1,1,0,1,0,0,0,0,2,0,1,
			},
			{0,1,2,4,6,7},
			{4,6}
		},
	},
};


const M2_5881Ref::sbox M2_5881Ref::fn2_sboxes[4][4] = {
	{   // 1st round
		{
			{
				3,3,0,1,0,1,0,0,0,3,0,0,1,3,1,2,0,3,3,3,2,1,0,1,1,1,2,2,2,3,2,2,
				2,1,3,3,1,3,1,1,0,0,1,2,0,2,2,1,1,2,3,1,2,1,3,1,2,2,0,1,3,0,2,2,
			},
			{1,3,4,5,6,7},
			{0,7}
		},

		{
			{
				0,1,3,0,1,1,2,3,2,0,0,3,2,1,3,1,3,3,0,0,1,0,0,3,0,3,3,2,3,2,0,1,
				3,2,3,2,2,1,3,1,1,1,0,3,3,2,2,1,1,2,0,2,0,1,1,0,1,0,1,1,2,0,3,0,
			},
			{0,3,5,6,5,0},
			{1,2}
		},

		{
			{
				0,2,2,1,0,1,2,1,2,0,1,2,3,3,0,1,3,1,1,2,1,2,1,3,3,2,3,3,2,1,0,1,
				0,1,0,2,0,1,1,3,2,0,3,2,1,1,1,3,2,3,0,2,3,0,2,2,1,3,0,1,1,2,2,2,
			},
			{0,2,3,4,7,-1},
			{3,4}
		},

		{
			{
				2,3,1,3,2,0,1,2,0,0,3,3,3,3,3,1,2,0,2,1,2,3,0,2,0,1,0,3,0,2,1,0,
				2,3,0,1,3,0,3,2,3,1,2,0,3,1,1,2,0,3,0,0,2,0,2,1,2,2,3,2,1,2,3,1,
			},
			{1,2,5,6,-1,-1},
			{5,6}
		},
	},
	{   // 2nd round
		{
			{
				2,3,1,3,1,0,3,3,3,2,3,3,2,0,0,3,2,3,0,3,1,1,2,3,1,1,2,2,0,1,0,0,
				2,1,0,1,2,0,1,2,0,3,1,1,2,3,1,2,0,2,0,1,3,0,1,0,2,2,3,0,3,2,3,0,
			},
			{0,1,4,5,6,7},
			{0,7}
		},

		{
			{
				0,2,2,0,2,2,0,3,2,3,2,1,3,2,3,3,1,1,0,0,3,0,2,1,1,3,3,2,3,2,0,1,
				1,2,3,0,1,0,3,0,3,1,0,2,1,2,0,3,2,3,1,2,2,0,3,2,3,0,0,1,2,3,3,3,
			},
			{0,2,3,6,7,-1},
			{1,5}
		},

		{
			{
				1,0,3,0,0,1,2,1,0,0,1,0,0,0,2,3,2,2,0,2,0,1,3,0,2,0,1,3,2,3,0,1,
				1,2,2,2,1,3,0,3,0,1,1,0,3,2,3,3,2,0,0,3,1,2,1,3,3,2,1,0,2,1,2,3,
			},
			{2,3,4,6,7,2},
			{2,3}
		},

		{
			{
				2,3,1,3,1,1,2,3,3,1,1,0,1,0,2,3,2,1,0,0,2,2,0,1,0,2,2,2,0,2,1,0,
				3,1,2,3,1,3,0,2,1,0,1,0,0,1,2,2,3,2,3,1,3,2,1,1,2,0,2,1,3,3,1,0,
			},
			{1,2,3,4,5,6},
			{4,6}
		},
	},
	{   // 3rd round
		{
			{
				0,3,0,1,3,0,0,2,1,0,1,3,2,2,2,0,3,3,3,0,2,2,0,3,0,0,2,3,0,3,2,1,
				3,3,0,3,0,2,3,3,1,1,1,0,2,2,1,1,3,0,3,1,2,0,2,0,0,0,3,2,1,1,0,0,
			},
			{1,4,5,6,7,5},
			{0,5}
		},

		{
			{
				0,3,0,1,3,0,3,1,3,2,2,2,3,0,3,2,2,1,2,2,0,3,2,2,0,0,2,1,1,3,2,3,
				2,3,3,1,2,0,1,2,2,1,0,0,0,0,2,3,1,2,0,3,1,3,1,2,3,2,1,0,3,0,0,2,
			},
			{0,2,3,4,6,7},
			{1,7}
		},

		{
			{
				2,2,0,3,0,3,1,0,1,1,2,3,2,3,1,0,0,0,3,2,2,0,2,3,1,3,2,0,3,3,1,3,
				// unused?
				255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,
			},
			{1,2,4,7,2,-1},
			{2,4}
		},

		{
			{
				0,2,3,1,3,1,1,0,0,1,3,0,2,1,3,3,2,0,2,1,1,2,3,3,0,0,0,2,0,2,3,0,
				3,3,3,3,2,3,3,2,3,0,1,0,2,3,3,2,0,1,3,1,0,1,2,3,3,0,2,0,3,0,3,3,
			},
			{0,1,2,3,5,7},
			{3,6}
		},
	},
	{   // 4th round
		{
			{
				0,1,1,0,0,1,0,2,3,3,0,1,2,3,0,2,1,0,3,3,2,0,3,0,0,2,1,0,1,0,1,3,
				0,3,3,1,2,0,3,0,1,3,2,0,3,3,1,3,0,2,3,3,2,1,1,2,2,1,2,1,2,0,1,1,
			},
			{0,1,2,4,7,-1},
			{0,5}
		},

		{
			{
				2,0,0,2,3,0,2,3,3,1,1,1,2,1,1,0,0,2,1,0,0,3,1,0,0,3,3,0,1,0,1,2,
				0,2,0,2,0,1,2,3,2,1,1,0,3,3,3,3,3,3,1,0,3,0,0,2,0,3,2,0,2,2,0,1,
			},
			{0,1,3,5,6,-1},
			{1,3}
		},

		{
			{
				0,1,1,2,1,3,1,1,0,0,3,1,1,1,2,0,3,2,0,1,1,2,3,3,3,0,3,0,0,2,0,3,
				3,2,0,0,3,2,3,1,2,3,0,3,2,0,1,2,2,2,0,2,0,1,2,2,3,1,2,2,1,1,1,1,
			},
			{0,2,3,4,5,7},
			{2,7}
		},

		{
			{
				0,1,2,0,3,3,0,3,2,1,3,3,0,3,1,1,3,2,3,2,3,0,0,0,3,0,2,2,3,2,2,3,
				2,2,3,1,2,3,1,2,0,3,0,2,3,1,0,0,3,2,1,2,1,2,1,3,1,0,2,3,3,1,3,2,
			},
			{2,3,4,5,6,7},
			{4,6}
		},
	},
};

const int M2_5881Ref::fn1_game_key_scheduling[FN1GK][2] = {
	{1,29},  {1,71},  {2,4},   {2,54},  {3,8},   {4,56},  {4,73},  {5,11},
	{6,51},  {7,92},  {8,89},  {9,9},   {9,39},  {9,58},  {10,90}, {11,6},
	{12,64}, {13,49}, {14,44}, {15,40}, {16,69}, {17,15}, {18,23}, {18,43},
	{19,82}, {20,81}, {21,32}, {22,5},  {23,66}, {24,13}, {24,45}, {25,12},
	{25,35}, {26,61}, {27,10}, {27,59}, {28,25}, {29,86}
};

const int M2_5881Ref::fn2_game_key_scheduling[FN2GK][2] = {
	{0,0},   {1,3},   {2,11},  {3,20},  {4,22},  {5,23},  {6,29},  {7,38},
	{8,39},  {9,55},  {9,86},  {9,87},  {10,50}, {11,57}, {12,59}, {13,61},
	{14,63}, {15,67}, {16,72}, {17,83}, {18,88}, {19,94}, {20,35}, {21,17},
	{22,6},  {23,85}, {24,16}, {25,25}, {26,92}, {27,47}, {28,28}, {29,90}
};

const int M2_5881Ref::fn1_sequence_key_scheduling[20][2] = {
	{0,52},  {1,34},  {2,17},  {3,36}, {4,84},  {4,88},  {5,57},  {6,48},
	{6,68},  {7,76},  {8,83},  {9,30}, {10,22}, {10,41}, {11,38}, {12,55},
	{13,74}, {14,19}, {14,80}, {15,26}
};

const int M2_5881Ref::fn2_sequence_key_scheduling[16] = {77,34,8,42,36,27,69,66,13,9,79,31,49,7,24,64};

const int M2_5881Ref::fn2_middle_result_scheduling[16] = {1,10,44,68,74,78,81,95,2,4,30,40,41,51,53,58};

inline int M2_5881Ref::feistel_function(int input, const struct sbox *sboxes, uint32_t subkeys)
{
	int k,m;
	int aux;
	int result=0;

	for (m=0; m<4; ++m) { // 4 sboxes
		for (k=0, aux=0; k<6; ++k)
			if (sboxes[m].inputs[k]!=-1)
				aux |= BIT(input, sboxes[m].inputs[k]) << k;

		aux = sboxes[m].table[(aux^subkeys)&0x3f];

		for (k=0; k<2; ++k)
			result |= BIT(aux,k) << sboxes[m].outputs[k];

		subkeys >>=6;
	}

	return result;
}

/**************************
This implementation is an "educational" version. It must be noted that it can be speed-optimized in a number of ways.
The most evident one is to factor out the parts of the key-scheduling that must only be done once (like the game-key &
sequence-key parts) as noted in the comments inlined in the function. More sophisticated speed-ups can be gained by
noticing that the weak key-scheduling would allow to create some pregenerated look-up tables for doing most of the work
of the function. Even so, it would still be pretty slow, so caching techniques could be a wiser option here.
**************************/

inline uint16_t M2_5881Ref::block_decrypt(uint32_t game_key, uint16_t sequence_key, uint16_t counter, uint16_t data)
{
	int j;
	int aux, aux2;
	int A, B;
	int middle_result;
	uint32_t fn1_subkeys[4];
	uint32_t fn2_subkeys[4];

	/* Game-key scheduling; this could be done just once per game at initialization time */
	memset(fn1_subkeys, 0, sizeof(uint32_t) * 4);
	memset(fn2_subkeys, 0, sizeof(uint32_t) * 4);

	for (j = 0; j < FN1GK; ++j) {
		if (BIT(game_key, fn1_game_key_scheduling[j][0]) != 0) {
			aux = fn1_game_key_scheduling[j][1] % 24;
			aux2 = fn1_game_key_scheduling[j][1] / 24;
			fn1_subkeys[aux2] ^= (1 << aux);
		}
	}

	for (j = 0; j < FN2GK; ++j) {
		if (BIT(game_key, fn2_game_key_scheduling[j][0]) != 0) {
			aux = fn2_game_key_scheduling[j][1] % 24;
			aux2 = fn2_game_key_scheduling[j][1] / 24;
			fn2_subkeys[aux2] ^= (1 << aux);
		}
	}
	/********************************************************/

	/* Sequence-key scheduling; this could be done just once per decryption run */
	for (j = 0; j < 20; ++j) {
		if (BIT(sequence_key, fn1_sequence_key_scheduling[j][0]) != 0) {
			aux = fn1_sequence_key_scheduling[j][1] % 24;
			aux2 = fn1_sequence_key_scheduling[j][1] / 24;
			fn1_subkeys[aux2] ^= (1 << aux);
		}
	}

	for (j = 0; j < 16; ++j) {
		if (BIT(sequence_key, j) != 0) {
			aux = fn2_sequence_key_scheduling[j] % 24;
			aux2 = fn2_sequence_key_scheduling[j] / 24;
			fn2_subkeys[aux2] ^= (1 << aux);
		}
	}

	/**************************************************************/

	// First Feistel Network

	aux = bitswap<16>(counter, 5, 12, 14, 13, 9, 3, 6, 4, 8, 1, 15, 11, 0, 7, 10, 2);

	// 1st round
	B = aux >> 8;
	A = (aux & 0xff) ^ feistel_function(B, fn1_sboxes[0], fn1_subkeys[0]);

	// 2nd round
	B ^= feistel_function(A, fn1_sboxes[1], fn1_subkeys[1]);

	// 3rd round
	A ^= feistel_function(B, fn1_sboxes[2], fn1_subkeys[2]);

	// 4th round
	B ^= feistel_function(A, fn1_sboxes[3], fn1_subkeys[3]);

	middle_result = (B << 8) | A;


	/* Middle-result-key sheduling */
	for (j = 0; j < 16; ++j) {
		if (BIT(middle_result, j) != 0) {
			aux = fn2_middle_result_scheduling[j] % 24;
			aux2 = fn2_middle_result_scheduling[j] / 24;
			fn2_subkeys[aux2] ^= (1 << aux);
		}
	}
	/*********************/

	// Second Feistel Network

	aux = bitswap<16>(data, 14, 3, 8, 12, 13, 7, 15, 4, 6, 2, 9, 5, 11, 0, 1, 10);

	// 1st round
	B = aux >> 8;
	A = (aux & 0xff) ^ feistel_function(B, fn2_sboxes[0], fn2_subkeys[0]);

	// 2nd round
	B ^= feistel_function(A, fn2_sboxes[1], fn2_subkeys[1]);

	// 3rd round
	A ^= feistel_function(B, fn2_sboxes[2], fn2_subkeys[2]);

	// 4th round
	B ^= feistel_function(A, fn2_sboxes[3], fn2_subkeys[3]);

	aux = (B << 8) | A;

	aux = bitswap<16>(aux, 15, 7, 6, 14, 13, 12, 5, 4, 3, 2, 11, 10, 9, 1, 0, 8);

	return aux;
}


inline uint16_t M2_5881Ref::get_decrypted_16()
{
	uint16_t enc;

	enc = m_read(prot_cur_address);

	uint16_t dec = block_decrypt(key, subkey, prot_cur_address, enc);
	uint16_t res = (dec & 3) | (dec_hist & 0xfffc);
	dec_hist = dec;

	prot_cur_address ++;

//  printf("get_decrypted_16 %04x\n", res);

	return res;
}


inline void M2_5881Ref::enc_start()
{
	block_pos = 0;
	done_compression = 0;
	buffer_pos = BUFFER_SIZE;

	if (buffer_bit2 < 14) // if we have remaining bits in the decompression buffer we shouldn't read the next word yet but should instead use the bits we have?? (twcup98 needs this, twsoc98 value is 14 on title screen and expects normal logic)
	{
//      printf("buffer_bit2 is %d\n", buffer_bit2);
		dec_header = (buffer2a & 0x0003) << 16;
	}
	else
	{
		dec_hist = 0; // seems to be needed by astrass at least otherwise any call after the first one will be influenced by the one before it.
		dec_header = get_decrypted_16() << 16;
	}

	dec_header |= get_decrypted_16();

	// the lower header bits are 2 values that multiply together to get the current stream length
	// in astrass the first block is 0xffff (for a 0x10000 block) followed by 0x3f3f (for a 0x1000 block)
	// etc. after each block a new header must be read, it looks like compressed and uncompressed blocks
	// can be mixed like this, I don't know if the length is src length of decompressed length.
	// deathcox and others confirm format as 0x20000 bit as compressed bit, 0x1ff00 bits as block size 1, 0x000ff bits as block size 2
	// for compressed streams the 'line size' is block size 1.

	block_numlines = ((dec_header & 0x000000ff) >> 0) + 1;
	int blocky = ((dec_header & 0x0001ff00) >> 8) + 1;
	block_size = block_numlines * blocky;

	if(dec_header & FLAG_COMPRESSED) {
		line_buffer_size = blocky;
		line_buffer_pos = line_buffer_size;
		buffer_bit = 7;
		buffer_bit2 = 15;
	}

	enc_ready = true;
}

inline void M2_5881Ref::enc_fill()
{
	assert(buffer_pos == BUFFER_SIZE);
	for(int i = 0; i != BUFFER_SIZE; i+=2) {
		uint16_t val = get_decrypted_16();
		buffer[i] = val;
		buffer[i+1] = val >> 8;
		block_pos+=2;

		if (!(dec_header & FLAG_COMPRESSED))
		{
			if (block_pos == block_size)
			{
				// if we reach the size specified we need to read a new header
				// todo: for compressed blocks this depends on OUTPUT size, not input size, so things get messy

				enc_start();
			}
		}
	}
	buffer_pos = 0;
}

/* node format
0xxxxxxx - next node index
1a0bbccc - end node
           a - 0 = repeat
               1 = fetch
           b - if a = 1
               00 - fetch  0
               01 - fetch  1
               11 - fetch -1
               if a = 0
               000
           c - repeat/fetch counter
               count = ccc + 1
11111111 - empty node
*/
const uint8_t M2_5881Ref::trees[9][2][32] = {
	{
		{0x01,0x10,0x0f,0x05,0xc4,0x13,0x87,0x0a,0xcc,0x81,0xce,0x0c,0x86,0x0e,0x84,0xc2,
			0x11,0xc1,0xc3,0xcf,0x15,0xc8,0xcd,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,},
		{0xc7,0x02,0x03,0x04,0x80,0x06,0x07,0x08,0x09,0xc9,0x0b,0x0d,0x82,0x83,0x85,0xc0,
			0x12,0xc6,0xc5,0x14,0x16,0xca,0xcb,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,},
	},
	{
		{0x02,0x80,0x05,0x04,0x81,0x10,0x15,0x82,0x09,0x83,0x0b,0x0c,0x0d,0xdc,0x0f,0xde,
			0x1c,0xcf,0xc5,0xdd,0x86,0x16,0x87,0x18,0x19,0x1a,0xda,0xca,0xc9,0x1e,0xce,0xff,},
		{0x01,0x17,0x03,0x0a,0x08,0x06,0x07,0xc2,0xd9,0xc4,0xd8,0xc8,0x0e,0x84,0xcb,0x85,
			0x11,0x12,0x13,0x14,0xcd,0x1b,0xdb,0xc7,0xc0,0xc1,0x1d,0xdf,0xc3,0xc6,0xcc,0xff,},
	},
	{
		{0xc6,0x80,0x03,0x0b,0x05,0x07,0x82,0x08,0x15,0xdc,0xdd,0x0c,0xd9,0xc2,0x14,0x10,
			0x85,0x86,0x18,0x16,0xc5,0xc4,0xc8,0xc9,0xc0,0xcc,0xff,0xff,0xff,0xff,0xff,0xff,},
		{0x01,0x02,0x12,0x04,0x81,0x06,0x83,0xc3,0x09,0x0a,0x84,0x11,0x0d,0x0e,0x0f,0x19,
			0xca,0xc1,0x13,0xd8,0xda,0xdb,0x17,0xde,0xcd,0xcb,0xff,0xff,0xff,0xff,0xff,0xff,},
	},
	{
		{0x01,0x80,0x0d,0x04,0x05,0x15,0x83,0x08,0xd9,0x10,0x0b,0x0c,0x84,0x0e,0xc0,0x14,
			0x12,0xcb,0x13,0xca,0xc8,0xc2,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,},
		{0xc5,0x02,0x03,0x07,0x81,0x06,0x82,0xcc,0x09,0x0a,0xc9,0x11,0xc4,0x0f,0x85,0xd8,
			0xda,0xdb,0xc3,0xdc,0xdd,0xc1,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,},
	},
	{
		{0x01,0x80,0x06,0x0c,0x05,0x81,0xd8,0x84,0x09,0xdc,0x0b,0x0f,0x0d,0x0e,0x10,0xdb,
			0x11,0xca,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,},
		{0xc4,0x02,0x03,0x04,0xcb,0x0a,0x07,0x08,0xd9,0x82,0xc8,0x83,0xc0,0xc1,0xda,0xc2,
			0xc9,0xc3,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,},
	},
	{
		{0x01,0x02,0x06,0x0a,0x83,0x0b,0x07,0x08,0x09,0x82,0xd8,0x0c,0xd9,0xda,0xff,0xff,
			0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,},
		{0xc3,0x80,0x03,0x04,0x05,0x81,0xca,0xc8,0xdb,0xc9,0xc0,0xc1,0x0d,0xc2,0xff,0xff,
			0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,},
	},
	{
		{0x01,0x02,0x03,0x04,0x81,0x07,0x08,0xd8,0xda,0xd9,0xff,0xff,0xff,0xff,0xff,0xff,
			0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,},
		{0xc2,0x80,0x05,0xc9,0xc8,0x06,0x82,0xc0,0x09,0xc1,0xff,0xff,0xff,0xff,0xff,0xff,
			0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,},
	},
	{
		{0x01,0x80,0x04,0xc8,0xc0,0xd9,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,
			0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,},
		{0xc1,0x02,0x03,0x81,0x05,0xd8,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,
			0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,},
	},
	{
		{0x01,0xd8,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,
			0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,},
		{0xc0,0x80,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,
			0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,},
	},
};

inline int M2_5881Ref::get_compressed_bit()
{
//  if(buffer_pos == BUFFER_SIZE)
//      enc_fill();

	if (buffer_bit2 == 15)
	{
		buffer_bit2 = 0;
		buffer2a = get_decrypted_16();
		buffer2[0] = buffer2a;
		buffer2[1] = buffer2a >> 8;
	//  block_pos+=2;
		buffer_pos = 0;

	}
	else
	{
		buffer_bit2++;
	}

//  if (buffer_bit ==7) printf("using byte %02x\n", buffer2[(buffer_pos&1) ^ 1]);

	int res = (buffer2[(buffer_pos&1)^1] >> buffer_bit) & 1;
	buffer_bit--;
	if(buffer_bit == -1) {
		buffer_bit = 7;
		buffer_pos++;
	}
	return res;
}
inline void M2_5881Ref::line_fill()
{
	assert(line_buffer_pos == line_buffer_size);
	uint8_t *lp = line_buffer.get();
	uint8_t *lc = line_buffer_prev.get();

	line_buffer.swap(line_buffer_prev);

	line_buffer_pos = 0;

	for(int i=0; i != line_buffer_size;) {
		// vlc 0: start of line
		// vlc 1: interior of line
		// vlc 2-9: 7-1 bytes from end of line

		int slot = i ? i < line_buffer_size - 7 ? 1 : (i & 7) + 1 : 0;

		uint32_t tmp = 0;
		while (!(tmp&0x80))
			if(get_compressed_bit())
				tmp = trees[slot][1][tmp];
			else
				tmp = trees[slot][0][tmp];
		if(tmp != 0xff) {
			int count = (tmp & 7) + 1;

			if(tmp&0x40) {
				// Copy from previous line

				static int offsets[4] = {0, 1, 0, -1};
				int offset = offsets[(tmp & 0x18) >> 3];
				for(int j=0; j != count; j++) {
					lc[i^1] = lp[((i+offset) % line_buffer_size)^1];
					i++;
				}

			} else {
				// Get a byte in the stream and write n times
				uint8_t byte;
				byte =         get_compressed_bit()  << 1;
				byte = (byte | get_compressed_bit()) << 1;
				byte = (byte | get_compressed_bit()) << 1;
				byte = (byte | get_compressed_bit()) << 1;
				byte = (byte | get_compressed_bit()) << 1;
				byte = (byte | get_compressed_bit()) << 1;
				byte = (byte | get_compressed_bit()) << 1;
				byte =  byte | get_compressed_bit();
				for(int j=0; j != count; j++)
					lc[(i++)^1] = byte;

			}
		}
	}

	block_pos++;
	if (block_numlines == block_pos)
	{
		done_compression = 1;
	}
}
