#pragma once

#include <array>
#include <cstdint>
#include <string>
#include <vector>

// P4 foundation, deliberately NOT a wire capability. The owner must serialize
// calls with authorization/revocation and provide power-durable storage. Never
// use an SD implementation for OTA. No network token or credential belongs here.
namespace device_transfer::durable_operation {
constexpr size_t kCapacity = 4;
constexpr uint8_t kSchema = 1;
enum class Phase : uint8_t {
  Receiving = 1, Prepared, Accepted, Installed, Failed, Cancelled, Forgotten
};
enum class Result {
  Ok, Replay, Unavailable, Conflict, ForeignDevice, Invalid, Busy,
  TooLate, NotAccepted, SelectionMismatch, StorageFailure, Corrupt
};
struct Identity {
  std::string device; // authenticated ownership device ID, 32 lowercase hex
  std::string operation; // random operation ID, 32 lowercase hex
  std::string manifest; // SHA-256, 64 lowercase hex
  std::string signedManifest;
  std::string stream;
  uint64_t streamBytes = 0;
  std::string session; // existing content-derived session identity
  std::string map;
  bool operator==(const Identity &other) const;
};
struct Record {
  Identity identity;
  Phase phase = Phase::Receiving;
  uint64_t revision = 0;
  bool acknowledged = false;
};
// Two independent bounded slots. writeDurable must make the ENTIRE supplied
// image power-durable before returning true. Readback alone cannot satisfy this
// contract on ESP32 FAT/SD. A false return may have written some/all bytes.
class Storage {
public:
  virtual ~Storage() = default;
  virtual bool read(unsigned slot, std::vector<uint8_t> &bytes) = 0;
  virtual bool writeDurable(unsigned slot,
                            const std::vector<uint8_t> &bytes) = 0;
};
class Store {
public:
  Store(Storage &storage, std::string authenticatedDevice);
  Result restore();
  Result admit(const Identity &identity, uint64_t creationRevision);
  Result initializeAdmission(uint64_t seed);
  uint64_t admissionRevision() const { return generation_; }
  Result prepare(const Identity &identity);
  // Call only while the unique commit grant is owned. Persist accepted intent
  // BEFORE any boot-eligible .ready/pending/pointer writes.
  Result accept(const Identity &identity);
  Result cancel(const Identity &identity);
  // The renderer owner supplies the exact verified selection after its ACK.
  // Merely changing the active pointer MUST NOT call this function.
  Result rendererAcknowledged(const Identity &identity,
                              const std::string &manifest,
                              const std::string &signedManifest);
  Result fail(const Identity &identity);
  // Explicit client result acknowledgment; retains a tombstone, not a new ID.
  // No automatic eviction: unresolved work and replay history are bounded.
  Result acknowledgeResult(const Identity &identity);
  Result query(const Identity &identity, Record &record) const;
  Result queryID(const std::string &operation, Record &record) const;
  const std::array<Record, kCapacity> &records() const { return records_; }
private:
  Result admitInternal(const Identity &identity);
  Result transition(const Identity &, Phase);
  Result persist(std::array<Record, kCapacity> next);
  Result locate(const Identity &, size_t &) const;
  Storage &storage_;
  std::string device_;
  std::array<Record, kCapacity> records_{};
  uint64_t generation_ = 0;
  unsigned activeSlot_ = 1;
  bool ready_ = false;
};
} // namespace device_transfer::durable_operation
