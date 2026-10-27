import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'credentials_screen.dart';
import 'schedule_screen.dart';
import 'status_screen.dart';
import '../services/notification_service.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _selectedIndex = 1; // start on schedule tab
  late Future<SharedPreferences> _prefsFuture;

  @override
  void initState() {
    super.initState();
    _prefsFuture = SharedPreferences.getInstance();

    // Request notification permission after first frame — avoids crash on startup
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await NotificationService().init();
      await NotificationService().requestPermission();
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<SharedPreferences>(
      future: _prefsFuture,
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        final prefs = snap.data!;
        final screens = [
          CredentialsScreen(prefs: prefs),
          ScheduleScreen(prefs: prefs),
          StatusScreen(prefs: prefs),
        ];

        return Scaffold(
          body: IndexedStack(index: _selectedIndex, children: screens),
          bottomNavigationBar: NavigationBar(
            selectedIndex: _selectedIndex,
            onDestinationSelected: (i) => setState(() => _selectedIndex = i),
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.person_outline),
                selectedIcon: Icon(Icons.person),
                label: 'Account',
              ),
              NavigationDestination(
                icon: Icon(Icons.schedule_outlined),
                selectedIcon: Icon(Icons.schedule),
                label: 'Schedule',
              ),
              NavigationDestination(
                icon: Icon(Icons.dashboard_outlined),
                selectedIcon: Icon(Icons.dashboard),
                label: 'Status',
              ),
            ],
          ),
        );
      },
    );
  }
}
