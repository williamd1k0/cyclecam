#include "M5TimerCAM.h"
#include <WiFi.h>
#include <HTTPClient.h>
#include "configs.h"
#include "debug.h"

#define CAM_EXT_WAKEUP_PIN 4

#define LED_WARNING_WIFI 2
#define LED_WARNING_HTTP 3
#define LED_WARNING_CAMERA 4

static int next_photo_delay = 10;
static bool sub_time_spent = false;

void led_warning(int n_times) {
#if ENABLE_CAMERA_LED
    for (int i = 0; i < n_times; i++) {
        TimerCAM.Power.setLed(255);
        delay(100);
        TimerCAM.Power.setLed(0);
        if (i < n_times - 1) {
            delay(100);
        }
    }
#endif
}

bool init_camera() {
    if (!TimerCAM.Camera.begin()) {
        SERIAL_PRINTLN("Camera Init Fail");
        return false;
    }
    SERIAL_PRINTLN("Camera Init Success");
    TimerCAM.Camera.sensor->set_pixformat(TimerCAM.Camera.sensor, PIXFORMAT_JPEG);
    TimerCAM.Camera.sensor->set_framesize(TimerCAM.Camera.sensor, FRAMESIZE_QXGA);
    TimerCAM.Camera.sensor->set_vflip(TimerCAM.Camera.sensor, 1);
    TimerCAM.Camera.sensor->set_hmirror(TimerCAM.Camera.sensor, 0);
    return true;
}

void send_photo() {
    SERIAL_PRINTLN("making POST request");
    HTTPClient http;

    const size_t header_keys_size = 2;
    const char* header_keys[header_keys_size] = {
        "x-next-photo-delay",
        "x-sub-time-spent"
    };
    http.setConnectTimeout(10000);
    http.collectHeaders(header_keys, header_keys_size);
    http.begin(SERVER_HOST, SERVER_PORT, "/");
    http.setReuse(false);
    int16_t bat_level = TimerCAM.Power.getBatteryLevel();
    http.addHeader("x-battery-level", String(bat_level));

    int http_response_code = http.POST(TimerCAM.Camera.fb->buf, TimerCAM.Camera.fb->len);
    SERIAL_PRINTLN("HTTP Response code: " + String(http_response_code));

    if (http_response_code < 0) {
        next_photo_delay = -1;
        return;
    }

    if (http.headers() > 0) {
        String header_value = http.header("x-next-photo-delay");
        next_photo_delay = header_value.toInt();
        SERIAL_PRINTLN("Next programmed photo delay: " + header_value);
        header_value = http.header("x-sub-time-spent");
        sub_time_spent = header_value.toInt() > 0;
    }
    http.end();
}

bool take_photo() {
    if (!init_camera()) {
        SERIAL_PRINTLN("Failed to initialize camera");
        return false;
    }
#if ENABLE_CAMERA_LED
    TimerCAM.Power.setLed(255);
#endif
    bool photo_taken = TimerCAM.Camera.get();
#if ENABLE_CAMERA_LED
    TimerCAM.Power.setLed(0);
#endif
    return photo_taken;
}

void prepare_sleep() {
    TimerCAM.Camera.deinit();
    gpio_hold_en((gpio_num_t)POWER_HOLD_PIN);
    gpio_deep_sleep_hold_en();
    esp_sleep_enable_ext0_wakeup((gpio_num_t)CAM_EXT_WAKEUP_PIN, HIGH);
    while (digitalRead(CAM_EXT_WAKEUP_PIN) == HIGH) {
        delay(1);
    }
}

void make_sleep(int for_seconds) {
    prepare_sleep();
    SERIAL_PRINTLN("Waiting for next photo; sleeping for: " + String(for_seconds) + "s");
    esp_sleep_enable_timer_wakeup(for_seconds * 1000000);
    esp_deep_sleep_start();
}

bool init_wifi() {
    WiFi.mode(WIFI_STA);
    WiFi.begin(WIFI_SSID, WIFI_PASS);
    WiFi.setSleep(false);
    SERIAL_PRINTLN("");
    SERIAL_PRINT("Connecting to ");
    SERIAL_PRINTLN(WIFI_SSID);
    // Wait for connection
    int tries = 100;
    while (WiFi.status() != WL_CONNECTED) {
        delay(100);
        SERIAL_PRINT(".");
        if (--tries <= 0) {
            return false;
        }
    }
    SERIAL_PRINTLN("");

    SERIAL_PRINT("Connected to ");
    SERIAL_PRINTLN(WIFI_SSID);
    SERIAL_PRINT("IP address: ");
    SERIAL_PRINTLN(WiFi.localIP());
    return true;
}

void setup() {
    unsigned long timer = millis();
    SERIAL_BEGIN(115200);
    TimerCAM.begin(false);
    if (!init_wifi()) {
        SERIAL_PRINTLN("Failed to connect to WiFi");
        led_warning(LED_WARNING_WIFI);
        make_sleep(next_photo_delay);
        return;
    }
    if (!take_photo()) {
        SERIAL_PRINTLN("Failed to take photo");
        led_warning(LED_WARNING_CAMERA);
        make_sleep(next_photo_delay);
    } else {
        send_photo();
        TimerCAM.Camera.free();
        timer = millis() - timer;
        SERIAL_PRINTLN("Setup took: " + String(timer) + " ms");
        if (next_photo_delay < 0) {
            SERIAL_PRINTLN("Failed to send photo");
            led_warning(LED_WARNING_HTTP);
            next_photo_delay = 10;
        }
        if (sub_time_spent) {
            next_photo_delay = max(next_photo_delay - (int)(timer / 1000), 1);
        }
        make_sleep(next_photo_delay);
    }
}

void loop() {
}
