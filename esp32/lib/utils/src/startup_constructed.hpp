#pragma once

// Holds file-local mutable state whose declared defaults include a few
// non-zero values (sentinels, enum defaults). As a plain global such an object
// is constant-initialized into .data, so its whole initializer image, mostly
// zeros, occupies the application flash slot. The non-constexpr constructor
// makes initialization dynamic instead: the object lives in zero-filled .bss
// and is value-initialized to exactly the same member values during C++
// static initialization, before setup() or any task can observe it.
//
// Bind the existing name as a reference so callers stay unchanged:
//   static StartupConstructed<State> stateStorage;
//   static State &state = stateStorage.value;
template <typename T> struct StartupConstructed {
  StartupConstructed() noexcept : value() {}
  T value;
};
