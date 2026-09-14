# Radio country flags

257 bundled 24x16 RGB565 flag images from `country-flag-icons@1.6.20` (MIT;
adjacent LICENSE). These replace unsupported flag emoji and cost 197376 bitmap
bytes of flash, with only one 768-byte active canvas in RAM.

Obtain `package/3x2` via `npm pack country-flag-icons@1.6.20`, then run
`node esp32/tools/generate_world_radio_flags.cjs /path/to/package/3x2` with
`sharp` available in Node's module search path. The generated C++ is checked in;
firmware builds do not fetch assets. Unknown country codes hide the flag.

The place is retained as supplied by the station directory: a state if available,
otherwise the country. Thus France becomes flag + France, Utah becomes
US flag + Utah, with no trailing FR or US text.
