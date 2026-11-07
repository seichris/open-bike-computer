#pragma once
namespace epaper_ui {
void process();
void prepareFrame();
void previousScreen();
void nextScreen();
void moveFocus(int delta);
void activate();
void context();
void closeContext();
bool contextOpen();
}
