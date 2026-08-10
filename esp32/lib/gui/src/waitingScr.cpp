/**
 * @file waitingScr.cpp
 * @brief Branded pre-connection experience for the Bicino device
 */

#include "waitingScr.hpp"

#include "../../bicino_style/bicino_visual_style.hpp"
#include "../../images/src/bicino_app_qr.h"
#include "../../images/src/bicino_logo.h"
#include "battery.hpp"
#include "mainScr.hpp"
#include "preConnectionIcons.hpp"
#include "uiUpdatePolicy.hpp"
#include "waitingScreenLayout.hpp"

#include <cstring>

lv_obj_t *waitingScreen = nullptr;
volatile bool gpsReceivedFromApp = false;
volatile bool pendingTransitionToMap = false;

extern Battery battery;

namespace {

using pre_connection_presentation::Phase;
using pre_connection_presentation::Group;

lv_obj_t *waitingBattery = nullptr;
lv_timer_t *waitingBatteryTimer = nullptr;
lv_obj_t *fullBrand = nullptr;
lv_obj_t *compactBrand = nullptr;
lv_obj_t *welcomeGroup = nullptr;
lv_obj_t *pairingGroup = nullptr;
lv_obj_t *pairingCodeLabel = nullptr;
lv_obj_t *statusGroup = nullptr;
lv_obj_t *statusHeadline = nullptr;
lv_obj_t *statusCopy = nullptr;
lv_obj_t *statusArtwork[4] = {nullptr, nullptr, nullptr, nullptr};
bool hasDisplayedPhase = false;
Phase displayedPhase = Phase::Welcome;
uint32_t displayedPairingCode = UINT32_MAX;

const char *batterySymbol(uint8_t percentage) {
  if (percentage >= 80) {
    return LV_SYMBOL_BATTERY_FULL;
  }
  if (percentage >= 60) {
    return LV_SYMBOL_BATTERY_3;
  }
  if (percentage >= 40) {
    return LV_SYMBOL_BATTERY_2;
  }
  if (percentage >= 20) {
    return LV_SYMBOL_BATTERY_1;
  }
  return LV_SYMBOL_BATTERY_EMPTY;
}

void setLabelTextIfChanged(lv_obj_t *label, const char *text) {
  if (label != nullptr && text != nullptr &&
      std::strcmp(lv_label_get_text(label), text) != 0) {
    lv_label_set_text(label, text);
  }
}

void setVisible(lv_obj_t *object, bool visible) {
  if (object == nullptr) {
    return;
  }
  if (visible) {
    lv_obj_clear_flag(object, LV_OBJ_FLAG_HIDDEN);
  } else {
    lv_obj_add_flag(object, LV_OBJ_FLAG_HIDDEN);
  }
}

lv_obj_t *createTransparentGroup(lv_obj_t *parent) {
  lv_obj_t *group = lv_obj_create(parent);
  lv_obj_set_pos(group, 0, 0);
  lv_obj_set_size(group, TFT_WIDTH, TFT_HEIGHT);
  lv_obj_set_style_bg_opa(group, LV_OPA_TRANSP, 0);
  lv_obj_set_style_border_width(group, 0, 0);
  lv_obj_set_style_pad_all(group, 0, 0);
  lv_obj_clear_flag(group, LV_OBJ_FLAG_SCROLLABLE);
  return group;
}

lv_obj_t *createLabel(lv_obj_t *parent,
                      const waiting_screen_layout::Rect &rect,
                      const lv_font_t *font, lv_color_t textColor,
                      const char *text) {
  lv_obj_t *label = lv_label_create(parent);
  lv_obj_set_pos(label, rect.x, rect.y);
  lv_obj_set_size(label, rect.width, rect.height);
  lv_obj_set_style_text_font(label, font, 0);
  lv_obj_set_style_text_color(label, textColor, 0);
  lv_obj_set_style_text_align(label, LV_TEXT_ALIGN_CENTER, 0);
  lv_label_set_long_mode(label, LV_LABEL_LONG_WRAP);
  lv_label_set_text(label, text);
  return label;
}

lv_obj_t *createBrandLockup(lv_obj_t *parent,
                            const waiting_screen_layout::Rect &rect,
                            const lv_font_t *font, int16_t labelY) {
  lv_obj_t *lockup = lv_obj_create(parent);
  lv_obj_set_pos(lockup, rect.x, rect.y);
  lv_obj_set_size(lockup, rect.width, rect.height);
  lv_obj_set_style_bg_opa(lockup, LV_OPA_TRANSP, 0);
  lv_obj_set_style_border_width(lockup, 0, 0);
  lv_obj_set_style_pad_all(lockup, 0, 0);
  lv_obj_clear_flag(lockup, LV_OBJ_FLAG_SCROLLABLE);

  lv_obj_t *logo = lv_image_create(lockup);
  lv_image_set_src(logo, &bicino_logo);
  lv_obj_set_pos(logo, 0, static_cast<int16_t>((rect.height - 36) / 2));

  lv_obj_t *wordmark = lv_label_create(lockup);
  lv_obj_set_pos(wordmark, 45, labelY);
  lv_obj_set_size(wordmark, static_cast<int16_t>(rect.width - 45),
                  rect.height);
  lv_obj_set_style_text_font(wordmark, font, 0);
  lv_obj_set_style_text_color(wordmark, lv_color_white(), 0);
  lv_obj_set_style_text_align(wordmark, LV_TEXT_ALIGN_LEFT, 0);
  lv_label_set_text_static(wordmark, "Bicino");
  return lockup;
}

void refreshWaitingBatteryIndicator() {
  if (waitingBattery == nullptr) {
    return;
  }

  uint8_t percentage = 0;
  bool charging = false;
  char text[48];
  if (!battery.readBatteryStatus(percentage, charging)) {
    std::snprintf(text, sizeof(text), LV_SYMBOL_BATTERY_EMPTY " --%%");
    setLabelTextIfChanged(waitingBattery, text);
    return;
  }

  if (charging) {
    std::snprintf(text, sizeof(text), "%s %u%% %s", batterySymbol(percentage),
                  percentage, LV_SYMBOL_CHARGE);
  } else {
    std::snprintf(text, sizeof(text), "%s %u%%", batterySymbol(percentage),
                  percentage);
  }
  setLabelTextIfChanged(waitingBattery, text);
}

void updateWaitingBattery(lv_timer_t *) {
  if (waitingScreen != nullptr && lv_scr_act() == waitingScreen) {
    refreshWaitingBatteryIndicator();
  }
}

void waitingScreenEvent(lv_event_t *event) {
  if (waitingBatteryTimer == nullptr) {
    return;
  }
  const lv_event_code_t code = lv_event_get_code(event);
  if (code == LV_EVENT_SCREEN_LOADED) {
    refreshWaitingBatteryIndicator();
    lv_timer_resume(waitingBatteryTimer);
    lv_timer_reset(waitingBatteryTimer);
  } else if (code == LV_EVENT_SCREEN_UNLOADED) {
    lv_timer_pause(waitingBatteryTimer);
  }
}

void showStatusArtwork(pre_connection_icons::Artwork artwork) {
  for (uint8_t index = 0; index < 4; ++index) {
    setVisible(statusArtwork[index],
               index == static_cast<uint8_t>(artwork));
  }
}

void applyPhase(Phase phase, uint32_t pairingCode) {
  if (!pre_connection_presentation::needsUpdate(
          hasDisplayedPhase, displayedPhase, displayedPairingCode, phase,
          pairingCode)) {
    return;
  }

  const pre_connection_presentation::Content content =
      pre_connection_presentation::content(phase);
  const bool welcome = content.group == Group::Welcome;
  const bool pairing = content.group == Group::Pairing;
  const bool status = content.group == Group::Status;
  setVisible(fullBrand, welcome);
  setVisible(compactBrand, !welcome);
  setVisible(welcomeGroup, welcome);
  setVisible(pairingGroup, pairing);
  setVisible(statusGroup, status);

  if (pairing && pairingCode != displayedPairingCode) {
    char codeText[8];
    pre_connection_presentation::formatPairingCode(pairingCode, codeText);
    setLabelTextIfChanged(pairingCodeLabel, codeText);
    displayedPairingCode = pairingCode;
  }

  if (status) {
    showStatusArtwork(content.artwork);
    setLabelTextIfChanged(statusHeadline, content.headline);
    setLabelTextIfChanged(statusCopy, content.copy);
  }

  displayedPhase = phase;
  hasDisplayedPhase = true;
}

} // namespace

// Forward declaration
void loadMainScreen();

void checkPendingMapTransition() {
  if (pendingTransitionToMap) {
    const uint32_t startMs = millis();
    pendingTransitionToMap = false;
    Serial.printf("UI: pending map transition noticed at %lu ms\n",
                  static_cast<unsigned long>(startMs));
    log_i("Transitioning from waiting screen to map...");
    loadMainScreen();
    Serial.printf("UI: loadMainScreen completed in %lu ms\n",
                  static_cast<unsigned long>(millis() - startMs));
  }
}

void createWaitingScr() {
  log_i("createWaitingScr() called");

  waitingScreen = lv_obj_create(NULL);
  lv_obj_set_style_bg_color(waitingScreen, lv_color_black(), 0);
  lv_obj_set_style_bg_opa(waitingScreen, LV_OPA_COVER, 0);
  lv_obj_add_event_cb(waitingScreen, waitingScreenEvent, LV_EVENT_ALL,
                      nullptr);
  const auto layout = waiting_screen_layout::makeLayout(TFT_WIDTH, TFT_HEIGHT);

  waitingBattery = createLabel(waitingScreen, layout.battery,
                               &lv_font_montserrat_24, lv_color_white(), "");
  refreshWaitingBatteryIndicator();
  waitingBatteryTimer = lv_timer_create(
      updateWaitingBattery, ui_update_policy::kWaitingBatteryPeriodMs, NULL);
  lv_timer_pause(waitingBatteryTimer);

  fullBrand = createBrandLockup(waitingScreen, layout.fullBrand,
                                &lv_font_montserrat_38, -2);
  compactBrand = createBrandLockup(waitingScreen, layout.compactBrand,
                                   &lv_font_montserrat_24, 5);

  welcomeGroup = createTransparentGroup(waitingScreen);
  const pre_connection_presentation::Content welcomeContent =
      pre_connection_presentation::content(Phase::Welcome);
  createLabel(welcomeGroup, layout.welcomeHeadline, &lv_font_montserrat_42,
              lv_color_white(), welcomeContent.headline);
  lv_obj_t *qr = lv_image_create(welcomeGroup);
  lv_image_set_src(qr, &bicino_app_qr);
  lv_obj_set_pos(qr, layout.qr.x, layout.qr.y);
  createLabel(welcomeGroup, layout.welcomeCopy, &lv_font_montserrat_18,
              lv_color_hex(bicino_visual_style::SECONDARY_TEXT_RGB888),
              welcomeContent.copy);

  pairingGroup = createTransparentGroup(waitingScreen);
  const pre_connection_presentation::Content pairingContent =
      pre_connection_presentation::content(Phase::PairingComparison);
  createLabel(pairingGroup, layout.pairingHeadline,
              &lv_font_montserrat_38, lv_color_white(),
              pairingContent.headline);
  pairingCodeLabel = createLabel(
      pairingGroup, layout.pairingCode, &lv_font_montserrat_48,
      lv_color_hex(bicino_visual_style::PAIRING_AMBER_RGB888), "000 000");
  createLabel(pairingGroup, layout.pairingCopy, &lv_font_montserrat_18,
              lv_color_hex(bicino_visual_style::SECONDARY_TEXT_RGB888),
              pairingContent.copy);

  statusGroup = createTransparentGroup(waitingScreen);
  for (uint8_t index = 0; index < 4; ++index) {
    statusArtwork[index] = pre_connection_icons::create(
        statusGroup, static_cast<pre_connection_icons::Artwork>(index));
    lv_obj_set_pos(statusArtwork[index], layout.statusHero.x,
                   layout.statusHero.y);
  }
  statusHeadline = createLabel(statusGroup, layout.statusHeadline,
                               &lv_font_montserrat_38, lv_color_white(), "");
  statusCopy = createLabel(
      statusGroup, layout.statusCopy, &lv_font_montserrat_18,
      lv_color_hex(bicino_visual_style::SECONDARY_TEXT_RGB888), "");

  hasDisplayedPhase = false;
  displayedPairingCode = UINT32_MAX;
  applyPhase(Phase::Welcome, 0);
  log_i("waitingScreen created at 0x%p", waitingScreen);
}

void updateWaitingOwnershipStatus(
    const pre_connection_presentation::Snapshot &snapshot) {
  if (waitingScreen == nullptr) {
    return;
  }
  const Phase phase = pre_connection_presentation::resolve(snapshot);
  applyPhase(phase, snapshot.pairingCode);
  if (phase == Phase::PairingComparison && lv_scr_act() != waitingScreen) {
    // Pairing is a full pre-connection presentation, never a map/workout
    // overlay. Bring it on-panel before the physical render gate can arm.
    isMainScreen = false;
    lv_screen_load(waitingScreen);
  }
}

bool isWaitingPairingComparisonVisible() {
  return waitingScreen != nullptr &&
         pre_connection_presentation::isVisibleComparisonFrame(
             lv_scr_act() == waitingScreen, displayedPhase);
}
