import 'package:flutter/material.dart';

/// Display metadata for a template category.
class TemplateCategoryStyle {
  final String label;
  final IconData icon;
  final Color color;
  const TemplateCategoryStyle(this.label, this.icon, this.color);
}

const _categoryStyles = <String, TemplateCategoryStyle>{
  'general': TemplateCategoryStyle(
      'General', Icons.category_outlined, Color(0xFF8B5CF6)),
  'meeting': TemplateCategoryStyle(
      'Meeting', Icons.groups_outlined, Color(0xFF3B82F6)),
  'call': TemplateCategoryStyle(
      'Call', Icons.phone_in_talk_outlined, Color(0xFFE11D48)),
  'education': TemplateCategoryStyle(
      'Education', Icons.school_outlined, Color(0xFF16A34A)),
  'interview': TemplateCategoryStyle(
      'Interview', Icons.record_voice_over_outlined, Color(0xFFF97316)),
  'personal': TemplateCategoryStyle(
      'Personal', Icons.favorite_border, Color(0xFFDB2777)),
  'work': TemplateCategoryStyle(
      'Work', Icons.work_outline, Color(0xFF0891B2)),
};

TemplateCategoryStyle categoryStyle(String id) =>
    _categoryStyles[id] ?? _categoryStyles['general']!;

/// Icons a template can name in its JSON `icon` field.
const _icons = <String, IconData>{
  'description': Icons.description_outlined,
  'summary': Icons.auto_awesome_outlined,
  'checklist': Icons.checklist,
  'quote': Icons.format_quote,
  'chat': Icons.chat_bubble_outline,
  'list': Icons.format_list_bulleted,
  'lightbulb': Icons.lightbulb_outline,
  'groups': Icons.groups_outlined,
  'person': Icons.person_outline,
  'phone': Icons.phone_in_talk_outlined,
  'support': Icons.support_agent,
  'sales': Icons.trending_up,
  'school': Icons.school_outlined,
  'book': Icons.menu_book_outlined,
  'cards': Icons.style_outlined,
  'mic': Icons.mic_none,
  'podcast': Icons.podcasts,
  'briefcase': Icons.work_outline,
  'task': Icons.task_alt,
  'calendar': Icons.event_note_outlined,
  'flag': Icons.flag_outlined,
  'gavel': Icons.gavel,
  'rocket': Icons.rocket_launch_outlined,
  'refresh': Icons.refresh,
  'journal': Icons.edit_note,
  'cart': Icons.shopping_cart_outlined,
  'health': Icons.medical_services_outlined,
  'idea': Icons.tips_and_updates_outlined,
  'question': Icons.help_outline,
  'chart': Icons.bar_chart,
  'star': Icons.star_outline,
};

/// Names accepted for a template's `icon` field.
List<String> get templateIconNames => _icons.keys.toList();

IconData templateIcon(String name) =>
    _icons[name] ?? Icons.description_outlined;
