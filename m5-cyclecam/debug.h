#define DEBUG 0

#if DEBUG
  #define SERIAL_BEGIN(baud) Serial.begin(baud)
  #define SERIAL_PRINT(x) Serial.print(x)
  #define SERIAL_PRINTLN(x) Serial.println(x)
#else
  #define SERIAL_BEGIN(baud) ((void)0)
  #define SERIAL_PRINT(x) ((void)0)
  #define SERIAL_PRINTLN(x) ((void)0)
#endif
