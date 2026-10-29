#pragma once
#include "../device_transfer/durable_operation.hpp"
#include <string>

// Qualification gate: this opt-in protocol MUST NOT be enabled in production
// until power-cut and downgrade qualification is recorded for each board/card.
#ifndef MAP_OPERATIONS_V1_ENABLED
#define MAP_OPERATIONS_V1_ENABLED 0
#endif
namespace map_transfer {
namespace operation = device_transfer::durable_operation;
class MapOperationStorage final : public operation::Storage {
public:
  explicit MapOperationStorage(std::string root) : root_(std::move(root)) {}
  bool read(unsigned slot, std::vector<uint8_t> &bytes) override;
  bool writeDurable(unsigned slot, const std::vector<uint8_t> &bytes) override;
private:
  std::string path(unsigned slot) const;
  std::string root_;
};
std::string operationReceiptJson(const operation::Record &record);
const char *operationPhaseName(operation::Phase phase);
// This validates only accepted authorization, never renderer completion.
bool acceptedMapOperation(const std::string &root, const std::string &device,
                          const std::string &operationID,
                          const std::string &session,
                          const std::string &manifest,
                          const std::string &signedManifest);
} // namespace map_transfer
