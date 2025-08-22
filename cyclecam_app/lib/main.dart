import 'dart:io';
import 'dart:typed_data';
import 'package:intl/intl.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:native_exif/native_exif.dart';
import 'package:path_provider/path_provider.dart';
import 'package:gal/gal.dart';
import 'package:flutter_background/flutter_background.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  bool hasPermissions = true;

  if (Platform.isAndroid) {
    final androidConfig = FlutterBackgroundAndroidConfig(
      notificationTitle: "Background Task Example",
      notificationText: "Running in the background",
      notificationImportance: AndroidNotificationImportance.high,
      enableWifiLock: true,
    );

    hasPermissions = await FlutterBackground.initialize(
      androidConfig: androidConfig,
    );
    if (!await Gal.hasAccess(toAlbum: true)) {
      await Gal.requestAccess(toAlbum: true);
    }
  }

  if (hasPermissions) {
    runApp(const CyclecamApp());
  }
}

class CyclecamApp extends StatelessWidget {
  const CyclecamApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: "Cyclecam",
      theme: ThemeData(colorScheme: ColorScheme.dark()),
      home: const MainPage(),
    );
  }
}

class MainPage extends StatefulWidget {
  const MainPage({super.key});

  @override
  State<MainPage> createState() => _MainPageState();
}

class _MainPageState extends State<MainPage> {
  final GEO_LOCATION = false; // Not fully implemented/tested
  HttpServer? server;

  bool has_shown_exif_warning = false;
  bool show_capture_preview = true;
  bool exif_enabled = false;
  bool exif_comment_enabled = false;
  bool geo_enabled = false;
  String exif_comment = "Cyclecam - Captured Photo";
  int capture_frequency = 5; // seconds
  bool sub_time_spent = true;
  int camera_battery_level = -1;

  Image? camera_frame;
  int frame_count = 0;

  Future<bool> _checkLocationPermission() async {
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        return false;
      }
    }
    if (permission == LocationPermission.deniedForever) {
      return false;
    }
    return true;
  }

  Future<bool> _checkLocationServices() async {
    return await Geolocator.isLocationServiceEnabled();
  }

  startServer() async {
    final album_timestamp = DateTime.now();
    if (Platform.isAndroid) {
      final bg_allowed = await FlutterBackground.enableBackgroundExecution();
      debugPrint(
        bg_allowed
            ? "Background execution enabled successfully."
            : "Failed to enable background execution.",
      );
    }
    // NOTE: When starting the server on Android with hotspot enabled, the IP address is usually 192.168.43.1
    server = await HttpServer.bind('0.0.0.0', 8080);
    setState(() {});
    debugPrint(
      "Server running on IP : ${server!.address} On Port : ${server!.port}",
    );
    await for (var request in server!) {
      if (request.method == 'POST') {
        debugPrint(request.headers.toString());
        int camera_battery = camera_battery_level;
        if (request.headers.value('x-battery-level') != null) {
          camera_battery =
              int.tryParse(request.headers.value('x-battery-level')!) ??
              camera_battery_level;
        }
        final content = await request.fold<List<int>>(
          [],
          (buffer, data) => buffer..addAll(data),
        );
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.add('x-next-photo-delay', capture_frequency.toString())
          ..headers.add('x-sub-time-spent', sub_time_spent ? '1' : '0')
          ..write('');
        await request.response.close();
        frame_count++;
        final timestamp = DateTime.now();
        final directory = await getApplicationDocumentsDirectory();
        final capture_dir = Directory(
          '${directory.path}/captures-${DateFormat('yyyyMMdd').format(album_timestamp)}',
        );
        if (!await capture_dir.exists()) {
          await capture_dir.create(recursive: true);
        }
        final file = File(
          '${capture_dir.path}/captured_frame_${(timestamp.millisecondsSinceEpoch ~/ 1000).toString()}.jpg',
        );
        await file.writeAsBytes(content);
        debugPrint("Frame written to ${file.path}");
        if (exif_enabled) {
          debugPrint("EXIF enabled. Processing metadata...");
          final Map<String, String> exif_data = {
            'Make': 'M5Stack',
            'Model': 'TimerCamera F',
            'Software': 'Cyclecam',
          };
          final dateFormat = DateFormat('yyyy:MM:dd HH:mm:ss');
          exif_data['DateTimeOriginal'] = dateFormat.format(timestamp);
          if (geo_enabled) {
            debugPrint(
              await _checkLocationPermission()
                  ? "Location permission granted."
                  : "Location permission denied.",
            );
            debugPrint(
              await _checkLocationServices()
                  ? "Location services are enabled."
                  : "Location services are disabled.",
            );
            final localtion_settings = LocationSettings(
              accuracy: LocationAccuracy.high,
              timeLimit: Duration(seconds: (15).toInt()),
            );
            final position = await Geolocator.getCurrentPosition(
              locationSettings: localtion_settings,
            );
            exif_data['GPSLatitude'] = position.latitude.toString();
            exif_data['GPSLatitudeRef'] = position.latitude >= 0 ? 'N' : 'S';
            exif_data['GPSLongitude'] = position.longitude.toString();
            exif_data['GPSLongitudeRef'] = position.longitude >= 0 ? 'E' : 'W';
            exif_data['GPSAltitude'] = position.altitude.toString();
            exif_data['GPSAltitudeRef'] = position.altitude >= 0 ? '0' : '1';
            debugPrint(
              "Position: ${position.latitude}, ${position.longitude} (${position.altitude}m)",
            );
          }
          if (exif_comment_enabled) {
            exif_data['UserComment'] = exif_comment;
          }
          debugPrint("EXIF Data: $exif_data");
          final exif = await Exif.fromPath(file.path);
          await exif.writeAttributes(exif_data);
        }
        await Gal.putImage(
          file.path,
          album: "Cyclecam/Cyclecam-$album_timestamp",
        );
        if (await file.exists()) {
          try {
            await file.delete();
            debugPrint(
              "Local file deleted after saving to gallery: ${file.path}",
            );
          } catch (e) {
            debugPrint("Error deleting local file: $e");
          }
        }
        setState(() {
          camera_battery_level = camera_battery;
          if (show_capture_preview) {
            camera_frame = Image.memory(
              Uint8List.fromList(content),
              fit: BoxFit.contain,
            );
          }
        });
      } else {
        request.response
          ..statusCode = HttpStatus.methodNotAllowed
          ..write("Method Not Allowed")
          ..close();
      }
    }
  }

  @override
  void dispose() {
    server?.close();
    if (Platform.isAndroid) {
      FlutterBackground.disableBackgroundExecution();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: Text("Cyclecam"),
        leading: Icon(
          server == null ? Icons.pedal_bike : Icons.electric_bike,
          color: server == null ? null : Colors.green,
        ),
        actions: [
          Row(
            children: [
              Icon(Icons.add_photo_alternate),
              SizedBox(width: 8),
              Text(frame_count.toString()),
              SizedBox(width: 8),
              Icon(
                camera_battery_level == -1
                    ? Icons.battery_unknown
                    : Icons.battery_full,
              ),
              SizedBox(width: 8),
              Text(
                camera_battery_level == -1 ? '???%' : '$camera_battery_level%',
              ),
              SizedBox(width: 8),
            ],
          ),
        ],
      ),
      body: SingleChildScrollView(
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              camera_frame == null
                  ? Container(
                      width: double.infinity,
                      height: 200,
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.grey),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Center(
                        child: Text(
                          "No frame available yet.",
                          style: TextStyle(color: Colors.grey),
                        ),
                      ),
                    )
                  : show_capture_preview
                  ? Container(
                      width: double.infinity,
                      height: 200,
                      child: camera_frame,
                    )
                  : Container(
                      width: double.infinity,
                      height: 300,
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.grey),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Center(
                        child: Text(
                          "Capture preview is disabled.",
                          style: TextStyle(color: Colors.grey),
                        ),
                      ),
                    ),
              const SizedBox(height: 20),
              SwitchListTile(
                title: Text(
                  "Show Capture Preview",
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                subtitle: Text(
                  "Enable this to show a preview of the captured photo.\nDisable this to save resources.",
                  style: TextStyle(fontSize: 12.0, color: Colors.grey),
                ),
                value: show_capture_preview,
                onChanged: (value) {
                  setState(() {
                    show_capture_preview = value;
                  });
                },
              ),
              Row(
                children: [
                  Expanded(
                    child: ListTile(
                      title: Text(
                        "Capture Frequency (seconds)",
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      subtitle: Text(
                        "How often the camera should take photos",
                        style: TextStyle(fontSize: 12.0, color: Colors.grey),
                      ),
                    ),
                  ),
                  Container(
                    width: 100,
                    child: TextField(
                      decoration: InputDecoration(
                        border: OutlineInputBorder(),
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                      ),
                      keyboardType: TextInputType.number,
                      enabled: server == null,
                      controller: TextEditingController(
                        text: capture_frequency.toString(),
                      ),
                      onChanged: (value) {
                        setState(() {
                          capture_frequency =
                              int.tryParse(value) ?? capture_frequency;
                        });
                      },
                    ),
                  ),
                  SizedBox(width: 16),
                ],
              ),
              SwitchListTile(
                title: Text(
                  "Subtract Time Spent",
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                subtitle: Text(
                  "If enabled, time spent processing will be subtracted from delay to ensure consistent capture frequency.\nFor example, if processing takes 2 seconds and delay is 10 seconds, next capture will be after 8 seconds.",
                  style: TextStyle(fontSize: 12.0, color: Colors.grey),
                ),
                value: sub_time_spent,
                onChanged: server == null
                    ? (value) {
                        setState(() {
                          sub_time_spent = value;
                        });
                      }
                    : null,
              ),
              SwitchListTile(
                title: Text(
                  "Enable Metadata (EXIF)",
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                subtitle: Text(
                  "Enable this to save basic metadata with the photos, such as timestamp and device information.\nBe aware that this can be a privacy concern, especially if you share the photos publicly!",
                  style: TextStyle(fontSize: 12.0, color: Colors.grey),
                ),
                value: exif_enabled,
                onChanged: server == null
                    ? (value) {
                        setState(() {
                          if (value && !has_shown_exif_warning) {
                            showDialog(
                              context: context,
                              builder: (context) => AlertDialog(
                                title: Text("Warning"),
                                content: Text(
                                  "Enabling EXIF metadata will include sensitive information such as device details, timestamps and GPS coordinates (if geo location is enabled).\n\n"
                                  "Ensure you are aware of the privacy implications before proceeding.",
                                  style: TextStyle(
                                    fontSize: 14.0,
                                    color: Colors.red,
                                  ),
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () {
                                      has_shown_exif_warning = true;
                                      Navigator.of(context).pop();
                                    },
                                    child: const Text("OK"),
                                  ),
                                ],
                              ),
                            );
                          } else {
                            exif_enabled = value;
                            if (!exif_enabled) {
                              exif_comment_enabled = false;
                              geo_enabled = false;
                            }
                          }
                        });
                      }
                    : null,
              ),
              if (exif_enabled)
                SwitchListTile(
                  title: const Text(
                    "Enable Comment in EXIF",
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  subtitle: Column(
                    children: [
                      const Text(
                        "Enable this to save a comment in the EXIF metadata of the photos.\nThis can be useful for adding context or notes.",

                        style: TextStyle(fontSize: 12.0, color: Colors.grey),
                      ),
                      if (exif_comment_enabled)
                        TextField(
                          decoration: const InputDecoration(
                            labelText: "EXIF Comment",
                            hintText: "Enter comment for EXIF metadata",
                          ),
                          onChanged: server == null
                              ? (value) {
                                  exif_comment = value;
                                }
                              : null,
                          controller: TextEditingController(text: exif_comment),
                          enabled: server == null,
                        ),
                    ],
                  ),
                  value: exif_comment_enabled,
                  onChanged: server == null
                      ? (value) {
                          setState(() {
                            exif_comment_enabled = value;
                          });
                        }
                      : null,
                ),
              if (exif_enabled && GEO_LOCATION)
                SwitchListTile(
                  title: const Text(
                    "Enable Geo Location (Not fully implemented)",
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  subtitle: const Text(
                    "Enable this to save GPS coordinates with the photos. Requires location permissions.\nBe aware that this can be a privacy concern, especially if you share the photos publicly!",
                    style: TextStyle(fontSize: 12.0, color: Colors.grey),
                  ),
                  value: geo_enabled,
                  onChanged: server == null
                      ? (value) async {
                          if (value) {
                            _checkLocationPermission().then((hasPermission) {
                              if (hasPermission) {
                                _checkLocationServices().then((
                                  isEnabled,
                                ) async {
                                  if (isEnabled) {
                                    debugPrint(
                                      "Location services are enabled.",
                                    );
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                        content: Text(
                                          "Location services are enabled. Geo location will be saved with photos.",
                                        ),
                                      ),
                                    );
                                    setState(() {
                                      geo_enabled = value;
                                    });
                                  } else {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                        content: Text(
                                          "Location services are disabled. Please enable them to use geo location.",
                                        ),
                                      ),
                                    );
                                  }
                                });
                              } else {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text(
                                      "Location permissions are denied. Please allow location permissions to use geo location.",
                                    ),
                                  ),
                                );
                              }
                            });
                          } else {
                            setState(() {
                              geo_enabled = value;
                            });
                          }
                        }
                      : null,
                ),
              const SizedBox(height: 70),
            ],
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: server == null
            ? startServer
            : () async {
                await server!.close();
                if (Platform.isAndroid) {
                  await FlutterBackground.disableBackgroundExecution();
                }
                setState(() {
                  server = null;
                  camera_frame = null;
                });
              },
        tooltip: 'Start Photo Receiver',
        child: server == null
            ? const Icon(Icons.camera_rear)
            : const Icon(Icons.pause),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.startFloat,
    );
  }
}
