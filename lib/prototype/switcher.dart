// PROTOTYPE — floating bottom bar for cycling UI variants. Never ships:
// it renders nothing in release builds.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

class PrototypeSwitcher extends StatelessWidget {
  const PrototypeSwitcher({
    super.key,
    required this.label,
    required this.onPrev,
    required this.onNext,
  });

  final String label;
  final VoidCallback onPrev;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    if (kReleaseMode) return const SizedBox.shrink();
    return Align(
      alignment: Alignment.bottomCenter,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 20),
        child: Material(
          elevation: 10,
          color: const Color(0xFF17171C),
          borderRadius: BorderRadius.circular(999),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: const Icon(Icons.chevron_left, color: Colors.white),
                onPressed: onPrev,
                tooltip: '上一个变体 (←)',
              ),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'PROTOTYPE',
                    style: TextStyle(
                      color: Color(0xFFFF6B6B),
                      fontSize: 9,
                      letterSpacing: 2.5,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  Text(
                    label,
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                  ),
                ],
              ),
              IconButton(
                icon: const Icon(Icons.chevron_right, color: Colors.white),
                onPressed: onNext,
                tooltip: '下一个变体 (→)',
              ),
            ],
          ),
        ),
      ),
    );
  }
}
