import 'package:flutter/material.dart';

import 'home_screen.dart';
import 'theme.dart';

class AmyApp extends StatelessWidget {
  const AmyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Amy',
      debugShowCheckedModeBanner: false,
      theme: AmyTheme.data(),
      home: const HomeScreen(),
    );
  }
}
