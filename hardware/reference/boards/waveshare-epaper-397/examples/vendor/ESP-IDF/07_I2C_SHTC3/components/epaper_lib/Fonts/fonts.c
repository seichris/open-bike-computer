/************************************************
 * Some commonly used Chinese symbols and special symbols in UTF encoding are distributed in different code tables, covering an overly wide range. Therefore, we read some commonly used characters in GBK, perform one-to-one comparison encoding, and take the modulus to simplify the subsequent comparison and encoding difficulty
*************************************************/
#include "fonts.h"
#include <string.h>

// UTF-8 to GB2312 Conversion Table (Including Common Symbols and Chinese Characters)
typedef struct {
    uint32_t utf8_code;    // UTF-8 encoding (up to 3 bytes)
    uint16_t gb2312_code;  // GB2312 encoding
} utf8_to_gb2312_map_t;

// Conversion Table (Partial symbols, based on GB2312 character set)
static const utf8_to_gb2312_map_t conversion_table[] = {
    {0xE38080, 0xA1A1},   // 　 -> A1A1 
    {0xE38081, 0xA1A2},   // 、 -> A1A2 
    {0xE38082, 0xA1A3},   // 。 -> A1A3 
    {0xC2B7, 0xA1A4},     // · -> A1A4 
    {0xCB89, 0xA1A5},     // ˉ -> A1A5 
    {0xCB87, 0xA1A6},     // ˇ -> A1A6 
    {0xC2A8, 0xA1A7},     // ¨ -> A1A7 
    {0xE38083, 0xA1A8},   // 〃 -> A1A8 
    {0xE38085, 0xA1A9},   // 々 -> A1A9 
    {0xE28094, 0xA1AA},   // — -> A1AA 
    {0xEFBD9E, 0xA1AB},   // ～ -> A1AB
    {0xE280A6, 0xA1AC},   // … -> A1AC
    {0xE28098, 0xA1AE},   // ' -> A1AE 
    {0xE28099, 0xA1AF},   // ' -> A1AF

    {0xE2809C, 0xA1B0},   // " -> A1B0
    {0xE2809D, 0xA1B1},   // " -> A1B1
    {0xE38094, 0xA1B2},   // 〔 -> A1B2
    {0xE38095, 0xA1B3},   // 〕 -> A1B3
    {0xE38088, 0xA1B4},   // 〈 -> A1B4
    {0xE38089, 0xA1B5},   // 〉 -> A1B5
    {0xE3808A, 0xA1B6},   // 《 -> A1B6
    {0xE3808B, 0xA1B7},   // 》 -> A1B7
    {0xE3808C, 0xA1B8},   // 「 -> A1B8
    {0xE3808D, 0xA1B9},   // 」 -> A1B9
    {0xE3808E, 0xA1BA},   // 『 -> A1BA
    {0xE3808F, 0xA1BB},   // 』 -> A1BB
    {0xE38090, 0xA1BC},   // 〖 -> A1BC
    {0xE38091, 0xA1BD},   // 〗 -> A1BD
    {0xE3808E, 0xA1BE},   // 【 -> A1BE
    {0xE3808F, 0xA1BF},   // 】 -> A1BF

    {0xC2B1, 0xA1C0},     // ± -> A1C0
    {0xC397, 0xA1C1},     // × -> A1C1
    {0xC3B7, 0xA1C2},     // ÷ -> A1C2
    {0xE288B6, 0xA1C3},   // ∶ -> A1C3
    {0xE288A7, 0xA1C4},   // ∧ -> A1C4
    {0xE288A8, 0xA1C5},   // ∨ -> A1C5
    {0xE28891, 0xA1C6},   // ∑ -> A1C6
    {0xE2888F, 0xA1C7},   // ∏ -> A1C7
    {0xE288AA, 0xA1C8},   // ∪ -> A1C8
    {0xE288A9, 0xA1C9},   // ∩ -> A1C9
    {0xE28888, 0xA1CA},   // ∈ -> A1CA
    {0xE288B7, 0xA1CB},   // ∷ -> A1CB
    {0xE2889A, 0xA1CC},   // √ -> A1CC
    {0xE28AA5, 0xA1CD},   // ⊥ -> A1CD
    {0xE288A5, 0xA1CE},   // ∥ -> A1CE
    {0xE288A0, 0xA1CF},   // ∠ -> A1CF

    {0xE28C92, 0xA1D0},   // ⌒ -> A1D0
    {0xE28A99, 0xA1D1},   // ⊙ -> A1D1
    {0xE288AB, 0xA1D2},   // ∫ -> A1D2
    {0xE288AE, 0xA1D3},   // ∮ -> A1D3
    {0xE289A1, 0xA1D4},   // ≡ -> A1D4
    {0xE2898C, 0xA1D5},   // ≌ -> A1D5
    {0xE28988, 0xA1D6},   // ≈ -> A1D6
    {0xE288BD, 0xA1D7},   // ∽ -> A1D7
    {0xE2889D, 0xA1D8},   // ∝ -> A1D8
    {0xE289A0, 0xA1D9},   // ≠ -> A1D9
    {0xE289AE, 0xA1DA},   // ≮ -> A1DA
    {0xE289AF, 0xA1DB},   // ≯ -> A1DB
    {0xE289A4, 0xA1DC},   // ≤ -> A1DC
    {0xE289A5, 0xA1DD},   // ≥ -> A1DD
    {0xE2889E, 0xA1DE},   // ∞ -> A1DE
    {0xE288B5, 0xA1DF},   // ∵ -> A1DF

    {0xE288B4, 0xA1E0},   // ∴ -> A1E0
    {0xE29982, 0xA1E1},   // ♂ -> A1E1
    {0xE29980, 0xA1E2},   // ♀ -> A1E2
    {0xC2B0, 0xA1E3},     // ° -> A1E3
    {0xE280B2, 0xA1E4},   // ′ -> A1E4
    {0xE280B3, 0xA1E5},   // ″ -> A1E5
    {0xE28483, 0xA1E6},   // ℃ -> A1E6
    {0xEFBC84, 0xA1E7},   // ＄ -> A1E7
    {0xC2A4, 0xA1E8},     // ¤ -> A1E8
    {0xEFBFA0, 0xA1E9},   // ￠ -> A1E9
    {0xEFBFA1, 0xA1EA},   // ￡ -> A1EA
    {0xE280B0, 0xA1EB},   // ‰ -> A1EB
    {0xC2A7, 0xA1EC},     // § -> A1EC
    {0xE28496, 0xA1ED},   // № -> A1ED
    {0xE29886, 0xA1EE},   // ☆ -> A1EE
    {0xE29885, 0xA1EF},   // ★ -> A1EF 

    {0xE2968B, 0xA1F0},   // ○ -> A1F0
    {0xE2968F, 0xA1F1},   // ● -> A1F1
    {0xE2968E, 0xA1F2},   // ◎ -> A1F2
    {0xE29687, 0xA1F3},   // ◇ -> A1F3
    {0xE29686, 0xA1F4},   // ◆ -> A1F4
    {0xE296A1, 0xA1F5},   // □ -> A1F5
    {0xE296A0, 0xA1F6},   // ■ -> A1F6
    {0xE296B3, 0xA1F7},   // △ -> A1F7
    {0xE296B2, 0xA1F8},   // ▲ -> A1F8
    {0xE280BB, 0xA1F9},   // ※ -> A1F9
    {0xE28692, 0xA1FA},   // → -> A1FA
    {0xE28690, 0xA1FB},   // ← -> A1FB
    {0xE28691, 0xA1FC},   // ↑ -> A1FC
    {0xE28693, 0xA1FD},   // ↓ -> A1FD
    {0xE38093, 0xA1FE},   // 〓 -> A1FE

    {0xE285B0, 0xA2A1},   // ⅰ -> A2A1
    {0xE285B1, 0xA2A2},   // ⅱ -> A2A2
    {0xE285B2, 0xA2A3},   // ⅲ -> A2A3
    {0xE285B3, 0xA2A4},   // ⅳ -> A2A4
    {0xE285B4, 0xA2A5},   // ⅴ -> A2A5
    {0xE285B5, 0xA2A6},   // ⅵ -> A2A6
    {0xE285B6, 0xA2A7},   // ⅶ -> A2A7
    {0xE285B7, 0xA2A8},   // ⅷ -> A2A8
    {0xE285B8, 0xA2A9},   // ⅸ -> A2A9
    {0xE285B9, 0xA2AA},   // ⅹ -> A2AA

    {0xE29288, 0xA2B1},   // ⒈ -> A2B1
    {0xE29289, 0xA2B2},   // ⒉ -> A2B2
    {0xE2928A, 0xA2B3},   // ⒊ -> A2B3
    {0xE2928B, 0xA2B4},   // ⒋ -> A2B4
    {0xE2928C, 0xA2B5},   // ⒌ -> A2B5
    {0xE2928D, 0xA2B6},   // ⒍ -> A2B6
    {0xE2928E, 0xA2B7},   // ⒎ -> A2B7
    {0xE2928F, 0xA2B8},   // ⒏ -> A2B8
    {0xE29290, 0xA2B9},   // ⒐ -> A2B9
    {0xE29291, 0xA2BA},   // ⒑ -> A2BA
    {0xE29292, 0xA2BB},   // ⒒ -> A2BB
    {0xE29293, 0xA2BC},   // ⒓ -> A2BC
    {0xE29294, 0xA2BD},   // ⒔ -> A2BD
    {0xE29295, 0xA2BE},   // ⒕ -> A2BE
    {0xE29296, 0xA2BF},   // ⒖ -> A2BF

    {0xE29297, 0xA2C0},   // ⒗ -> A2C0
    {0xE29298, 0xA2C1},   // ⒘ -> A2C1
    {0xE29299, 0xA2C2},   // ⒙ -> A2C2
    {0xE2929A, 0xA2C3},   // ⒚ -> A2C3
    {0xE2929B, 0xA2C4},   // ⒛ -> A2C4
    {0xE291B4, 0xA2C5},   // ⑴ -> A2C5
    {0xE291B5, 0xA2C6},   // ⑵ -> A2C6
    {0xE291B6, 0xA2C7},   // ⑶ -> A2C7
    {0xE291B7, 0xA2C8},   // ⑷ -> A2C8
    {0xE291B8, 0xA2C9},   // ⑸ -> A2C9
    {0xE291B9, 0xA2CA},   // ⑹ -> A2CA
    {0xE291BA, 0xA2CB},   // ⑺ -> A2CB
    {0xE291BB, 0xA2CC},   // ⑻ -> A2CC
    {0xE291BC, 0xA2CD},   // ⑼ -> A2CD
    {0xE291BD, 0xA2CE},   // ⑽ -> A2CE
    {0xE291BE, 0xA2CF},   // ⑾ -> A2CF

    {0xE291BF, 0xA2D0},   // ⑿ -> A2D0
    {0xE29280, 0xA2D1},   // ⒀ -> A2D1
    {0xE29281, 0xA2D2},   // ⒁ -> A2D2
    {0xE29282, 0xA2D3},   // ⒂ -> A2D3
    {0xE29283, 0xA2D4},   // ⒃ -> A2D4
    {0xE29284, 0xA2D5},   // ⒄ -> A2D5
    {0xE29285, 0xA2D6},   // ⒅ -> A2D6
    {0xE29286, 0xA2D7},   // ⒆ -> A2D7
    {0xE29287, 0xA2D8},   // ⒇ -> A2D8
    {0xE291A0, 0xA2D9},   // ① -> A2D9
    {0xE291A1, 0xA2DA},   // ② -> A2DA
    {0xE291A2, 0xA2DB},   // ③ -> A2DB
    {0xE291A3, 0xA2DC},   // ④ -> A2DC
    {0xE291A4, 0xA2DD},   // ⑤ -> A2DD
    {0xE291A5, 0xA2DE},   // ⑥ -> A2DE
    {0xE291A6, 0xA2DF},   // ⑦ -> A2DF

    {0xE291A7, 0xA2E0},   // ⑧ -> A2E0
    {0xE291A8, 0xA2E1},   // ⑨ -> A2E1
    {0xE291A9, 0xA2E2},   // ⑩ -> A2E2
    {0xE388A0, 0xA2E5},   // ㈠ -> A2E5
    {0xE388A1, 0xA2E6},   // ㈡ -> A2E6
    {0xE388A2, 0xA2E7},   // ㈢ -> A2E7
    {0xE388A3, 0xA2E8},   // ㈣ -> A2E8
    {0xE388A4, 0xA2E9},   // ㈤ -> A2E9
    {0xE388A5, 0xA2EA},   // ㈥ -> A2EA
    {0xE388A6, 0xA2EB},   // ㈦ -> A2EB
    {0xE388A7, 0xA2EC},   // ㈧ -> A2EC
    {0xE388A8, 0xA2ED},   // ㈨ -> A2ED
    {0xE388A9, 0xA2EE},   // ㈩ -> A2EE

    {0xE28590, 0xA2F1},   // Ⅰ -> A2F1
    {0xE28591, 0xA2F2},   // Ⅱ -> A2F2
    {0xE28592, 0xA2F3},   // Ⅲ -> A2F3
    {0xE28593, 0xA2F4},   // Ⅳ -> A2F4
    {0xE28594, 0xA2F5},   // Ⅴ -> A2F5
    {0xE28595, 0xA2F6},   // Ⅵ -> A2F6
    {0xE28596, 0xA2F7},   // Ⅶ -> A2F7
    {0xE28597, 0xA2F8},   // Ⅷ -> A2F8
    {0xE28598, 0xA2F9},   // Ⅸ -> A2F9
    {0xE28599, 0xA2FA},   // Ⅹ -> A2FA
    {0xE2859A, 0xA2FB},   // Ⅺ -> A2FB
    {0xE2859B, 0xA2FC},   // Ⅻ -> A2FC

    {0xCE91, 0xA6A1},     // Α -> A6A1
    {0xCE92, 0xA6A2},     // Β -> A6A2
    {0xCE93, 0xA6A3},     // Γ -> A6A3
    {0xCE94, 0xA6A4},     // Δ -> A6A4
    {0xCE95, 0xA6A5},     // Ε -> A6A5
    {0xCE96, 0xA6A6},     // Ζ -> A6A6
    {0xCE97, 0xA6A7},     // Η -> A6A7
    {0xCE98, 0xA6A8},     // Θ -> A6A8
    {0xCE99, 0xA6A9},     // Ι -> A6A9
    {0xCE9A, 0xA6AA},     // Κ -> A6AA
    {0xCE9B, 0xA6AB},     // Λ -> A6AB
    {0xCE9C, 0xA6AC},     // Μ -> A6AC
    {0xCE9D, 0xA6AD},     // Ν -> A6AD
    {0xCE9E, 0xA6AE},     // Ξ -> A6AE
    {0xCE9F, 0xA6AF},     // Ο -> A6AF
    {0xCEA0, 0xA6B0},     // Π -> A6B0
    {0xCEA1, 0xA6B1},     // Ρ -> A6B1
    {0xCEA3, 0xA6B2},     // Σ -> A6B2
    {0xCEA4, 0xA6B3},     // Τ -> A6B3
    {0xCEA5, 0xA6B4},     // Υ -> A6B4
    {0xCEA6, 0xA6B5},     // Φ -> A6B5
    {0xCEA7, 0xA6B6},     // Χ -> A6B6
    {0xCEA8, 0xA6B7},     // Ψ -> A6B7
    {0xCEA9, 0xA6B8},     // Ω -> A6B8

    {0xCEB1, 0xA6C1},     // α -> A6C1
    {0xCEB2, 0xA6C2},     // β -> A6C2
    {0xCEB3, 0xA6C3},     // γ -> A6C3
    {0xCEB4, 0xA6C4},     // δ -> A6C4
    {0xCEB5, 0xA6C5},     // ε -> A6C5
    {0xCEB6, 0xA6C6},     // ζ -> A6C6
    {0xCEB7, 0xA6C7},     // η -> A6C7
    {0xCEB8, 0xA6C8},     // θ -> A6C8
    {0xCEB9, 0xA6C9},     // ι -> A6C9
    {0xCEBA, 0xA6CA},     // κ -> A6CA
    {0xCEBB, 0xA6CB},     // λ -> A6CB
    {0xCEBC, 0xA6CC},     // μ -> A6CC
    {0xCEBD, 0xA6CD},     // ν -> A6CD
    {0xCEBE, 0xA6CE},     // ξ -> A6CE
    {0xCEBF, 0xA6CF},     // ο -> A6CF
    {0xCEC0, 0xA6D0},     // π -> A6D0
    {0xCEC1, 0xA6D1},     // ρ -> A6D1
    {0xCEC3, 0xA6D2},     // σ -> A6D2
    {0xCEC4, 0xA6D3},     // τ -> A6D3
    {0xCEC5, 0xA6D4},     // υ -> A6D4
    {0xCEC6, 0xA6D5},     // φ -> A6D5
    {0xCEC7, 0xA6D6},     // χ -> A6D6
    {0xCEC8, 0xA6D7},     // ψ -> A6D7
    {0xCEC9, 0xA6D8},     // ω -> A6D8

    {0xD090, 0xA7A1},     // А -> A7A1
    {0xD091, 0xA7A2},     // Б -> A7A2
    {0xD092, 0xA7A3},     // В -> A7A3
    {0xD093, 0xA7A4},     // Г -> A7A4
    {0xD094, 0xA7A5},     // Д -> A7A5
    {0xD095, 0xA7A6},     // Е -> A7A6
    {0xD081, 0xA7A7},     // Ё -> A7A7
    {0xD096, 0xA7A8},     // Ж -> A7A8
    {0xD097, 0xA7A9},     // З -> A7A9
    {0xD098, 0xA7AA},     // И -> A7AA
    {0xD099, 0xA7AB},     // Й -> A7AB
    {0xD09A, 0xA7AC},     // К -> A7AC
    {0xD09B, 0xA7AD},     // Л -> A7AD
    {0xD09C, 0xA7AE},     // М -> A7AE
    {0xD09D, 0xA7AF},     // Н -> A7AF
    {0xD09E, 0xA7B0},     // О -> A7B0
    {0xD09F, 0xA7B1},     // П -> A7B1
    {0xD0A0, 0xA7B2},     // Р -> A7B2
    {0xD0A1, 0xA7B3},     // С -> A7B3
    {0xD0A2, 0xA7B4},     // Т -> A7B4
    {0xD0A3, 0xA7B5},     // У -> A7B5
    {0xD0A4, 0xA7B6},     // Ф -> A7B6
    {0xD0A5, 0xA7B7},     // Х -> A7B7
    {0xD0A6, 0xA7B8},     // Ц -> A7B8
    {0xD0A7, 0xA7B9},     // Ч -> A7B9
    {0xD0A8, 0xA7BA},     // Ш -> A7BA
    {0xD0A9, 0xA7BB},     // Щ -> A7BB
    {0xD0AA, 0xA7BC},     // Ъ -> A7BC
    {0xD0AB, 0xA7BD},     // Ы -> A7BD
    {0xD0AC, 0xA7BE},     // Ь -> A7BE
    {0xD0AD, 0xA7BF},     // Э -> A7BF

    {0xD0AE, 0xA7C0},     // Ю -> A7C0
    {0xD0AF, 0xA7C1},     // Я -> A7C1
    {0xD0B0, 0xA7D1},     // а -> A7D1
    {0xD0B1, 0xA7D2},     // б -> A7D2
    {0xD0B2, 0xA7D3},     // в -> A7D3
    {0xD0B3, 0xA7D4},     // г -> A7D4
    {0xD0B4, 0xA7D5},     // д -> A7D5
    {0xD0B5, 0xA7D6},     // е -> A7D6
    {0xD191, 0xA7D7},     // ё -> A7D7
    {0xD0B6, 0xA7D8},     // ж -> A7D8
    {0xD0B7, 0xA7D9},     // з -> A7D9
    {0xD0B8, 0xA7DA},     // и -> A7DA
    {0xD0B9, 0xA7DB},     // й -> A7DB
    {0xD0BA, 0xA7DC},     // к -> A7DC
    {0xD0BB, 0xA7DD},     // л -> A7DD
    {0xD0BC, 0xA7DE},     // м -> A7DE
    {0xD0BD, 0xA7DF},     // н -> A7DF
    {0xD0BE, 0xA7E0},     // о -> A7E0
    {0xD0BF, 0xA7E1},     // п -> A7E1
    {0xD180, 0xA7E2},     // р -> A7E2
    {0xD181, 0xA7E3},     // с -> A7E3
    {0xD182, 0xA7E4},     // т -> A7E4
    {0xD183, 0xA7E5},     // у -> A7E5
    {0xD184, 0xA7E6},     // ф -> A7E6
    {0xD185, 0xA7E7},     // х -> A7E7
    {0xD186, 0xA7E8},     // ц -> A7E8
    {0xD187, 0xA7E9},     // ч -> A7E9
    {0xD188, 0xA7EA},     // ш -> A7EA
    {0xD189, 0xA7EB},     // щ -> A7EB
    {0xD18A, 0xA7EC},     // ъ -> A7EC
    {0xD18B, 0xA7ED},     // ы -> A7ED
    {0xD18C, 0xA7EE},     // ь -> A7EE
    {0xD18D, 0xA7EF},     // э -> A7EF
    {0xD18E, 0xA7F0},     // ю -> A7F0
    {0xD18F, 0xA7F1},     // я -> A7F1

    {0xE29480, 0xA9A1},   // ─ -> A9A1
    {0xE29481, 0xA9A2},   // ━ -> A9A2
    {0xE29482, 0xA9A3},   // │ -> A9A3
    {0xE29483, 0xA9A4},   // ┃ -> A9A4
    {0xE29484, 0xA9A5},   // ┄ -> A9A5
    {0xE29485, 0xA9A6},   // ┅ -> A9A6
    {0xE29486, 0xA9A7},   // ┆ -> A9A7
    {0xE29487, 0xA9A8},   // ┇ -> A9A8
    {0xE29488, 0xA9A9},   // ┈ -> A9A9
    {0xE29489, 0xA9AA},   // ┉ -> A9AA
    {0xE2948A, 0xA9AB},   // ┊ -> A9AB
    {0xE2948B, 0xA9AC},   // ┋ -> A9AC
    {0xE2948C, 0xA9AD},   // ┌ -> A9AD
    {0xE2948D, 0xA9AE},   // ┍ -> A9AE
    {0xE2948E, 0xA9AF},   // ┎ -> A9AF
    {0xE2948F, 0xA9B0},   // ┏ -> A9B0
    {0xE29490, 0xA9B1},   // ┐ -> A9B1
    {0xE29491, 0xA9B2},   // ┑ -> A9B2
    {0xE29492, 0xA9B3},   // ┒ -> A9B3
    {0xE29493, 0xA9B4},   // ┓ -> A9B4
    {0xE29494, 0xA9B5},   // └ -> A9B5
    {0xE29495, 0xA9B6},   // ┕ -> A9B6
    {0xE29496, 0xA9B7},   // ┖ -> A9B7
    {0xE29497, 0xA9B8},   // ┗ -> A9B8
    {0xE29498, 0xA9B9},   // ┘ -> A9B9
    {0xE29499, 0xA9BA},   // ┙ -> A9BA
    {0xE2949A, 0xA9BB},   // ┚ -> A9BB
    {0xE2949B, 0xA9BC},   // ┛ -> A9BC
    {0xE2949C, 0xA9BD},   // ├ -> A9BD
    {0xE2949D, 0xA9BE},   // ┝ -> A9BE
    {0xE2949E, 0xA9BF},   // ┞ -> A9BF
    {0xE2949F, 0xA9C0},   // ┟ -> A9C0
    {0xE294A0, 0xA9C1},   // ┠ -> A9C1
    {0xE294A1, 0xA9C2},   // ┡ -> A9C2
    {0xE294A2, 0xA9C3},   // ┢ -> A9C3
    {0xE294A3, 0xA9C4},   // ┣ -> A9C4
    {0xE294A4, 0xA9C5},   // ┤ -> A9C5
    {0xE294A5, 0xA9C6},   // ┥ -> A9C6
    {0xE294A6, 0xA9C7},   // ┦ -> A9C7
    {0xE294A7, 0xA9C8},   // ┧ -> A9C8
    {0xE294A8, 0xA9C9},   // ┨ -> A9C9
    {0xE294A9, 0xA9CA},   // ┩ -> A9CA
    {0xE294AA, 0xA9CB},   // ┪ -> A9CB
    {0xE294AB, 0xA9CC},   // ┫ -> A9CC
    {0xE294AC, 0xA9CD},   // ┬ -> A9CD
    {0xE294AD, 0xA9CE},   // ┭ -> A9CE
    {0xE294AE, 0xA9CF},   // ┮ -> A9CF
    {0xE294AF, 0xA9D0},   // ┯ -> A9D0
    {0xE294B0, 0xA9D1},   // ┰ -> A9D1
    {0xE294B1, 0xA9D2},   // ┱ -> A9D2
    {0xE294B2, 0xA9D3},   // ┲ -> A9D3
    {0xE294B3, 0xA9D4},   // ┳ -> A9D4
    {0xE294B4, 0xA9D5},   // ┴ -> A9D5
    {0xE294B5, 0xA9D6},   // ┵ -> A9D6
    {0xE294B6, 0xA9D7},   // ┶ -> A9D7
    {0xE294B7, 0xA9D8},   // ┷ -> A9D8
    {0xE294B8, 0xA9D9},   // ┸ -> A9D9
    {0xE294B9, 0xA9DA},   // ┹ -> A9DA
    {0xE294BA, 0xA9DB},   // ┺ -> A9DB
    {0xE294BB, 0xA9DC},   // ┻ -> A9DC
    {0xE294BC, 0xA9DD},   // ┼ -> A9DD
    {0xE294BD, 0xA9DE},   // ┽ -> A9DE
    {0xE294BE, 0xA9DF},   // ┾ -> A9DF
    {0xE294BF, 0xA9E0},   // ┿ -> A9E0
    {0xE29580, 0xA9E1},   // ╀ -> A9E1
    {0xE29581, 0xA9E2},   // ╁ -> A9E2
    {0xE29582, 0xA9E3},   // ╂ -> A9E3
    {0xE29583, 0xA9E4},   // ╃ -> A9E4
    {0xE29584, 0xA9E5},   // ╄ -> A9E5
    {0xE29585, 0xA9E6},   // ╅ -> A9E6
    {0xE29586, 0xA9E7},   // ╆ -> A9E7
    {0xE29587, 0xA9E8},   // ╇ -> A9E8
    {0xE29588, 0xA9E9},   // ╈ -> A9E9
    {0xE29589, 0xA9EA},   // ╉ -> A9EA
    {0xE2958A, 0xA9EB},   // ╊ -> A9EB
    {0xE2958B, 0xA9EC},   // ╋ -> A9EC
};

// Convert UTF-8 characters to GB2312
uint16_t utf8_char_to_gb2312(const char* utf8_char, int* char_len)
{
    uint32_t unicode = 0;
    *char_len = 0;

    unsigned char c1 = utf8_char[0];
    if (c1 < 0x80) {
        *char_len = 1;
        return c1;
    } else if ((c1 & 0xE0) == 0xC0) {
        if (utf8_char[1] == 0) return 0;
        unicode = ((c1 & 0x1F) << 6) | (utf8_char[1] & 0x3F);
        *char_len = 2;
    } else if ((c1 & 0xF0) == 0xE0) {
        if (utf8_char[1] == 0 || utf8_char[2] == 0) return 0;
        unicode = (c1 << 16) | (utf8_char[1] << 8) | utf8_char[2];
        *char_len = 3;
    } else {
        return 0;
    }

    int table_size = sizeof(conversion_table) / sizeof(conversion_table[0]);
    for (int i = 0; i < table_size; i++) {
        if (conversion_table[i].utf8_code == unicode) {
            return conversion_table[i].gb2312_code;
        }
    }
    return 0;
}

// Convert UTF-8 strings to GB2312 strings
int utf8_string_to_gb2312(const char* utf8_str, char* gb2312_str, size_t gb2312_size)
{
    int utf8_pos = 0;
    int gb2312_pos = 0;
    int utf8_len = strlen(utf8_str);

    while (utf8_pos < utf8_len && gb2312_pos < gb2312_size - 2) {
        int char_len;
        uint16_t gb_code = utf8_char_to_gb2312(&utf8_str[utf8_pos], &char_len);

        if (gb_code == 0) {
            utf8_pos += char_len > 0 ? char_len : 1;
            continue;
        }

        if (gb_code < 0x100) {
            gb2312_str[gb2312_pos++] = gb_code;
        } else {
            gb2312_str[gb2312_pos++] = (gb_code >> 8) & 0xFF;
            gb2312_str[gb2312_pos++] = gb_code & 0xFF;
        }

        utf8_pos += char_len;
    }

    gb2312_str[gb2312_pos] = '\0';
    return gb2312_pos;
}






