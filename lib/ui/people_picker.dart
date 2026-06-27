import 'package:flutter/material.dart';

import '../models/category.dart';

/// A searchable member picker. With a real address book a flat checkbox list of
/// everyone is unusable, so this shows the currently-selected people by default
/// and reveals matches as you type (by name or phone digits).
///
/// Controlled: the parent owns the [selected] set and is told of each toggle
/// via [onChanged]. Renders as a plain [Column] (not its own scrollable) so it
/// drops into an existing `ListView` without nested-scroll trouble.
class PeoplePicker extends StatefulWidget {
  final List<Person> people;
  final Set<String> selected; // normalized phones
  final void Function(String phone, bool selected) onChanged;

  const PeoplePicker({
    super.key,
    required this.people,
    required this.selected,
    required this.onChanged,
  });

  @override
  State<PeoplePicker> createState() => _PeoplePickerState();
}

class _PeoplePickerState extends State<PeoplePicker> {
  final TextEditingController _controller = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.people.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Text('No people found yet.'),
      );
    }

    final q = _query.trim().toLowerCase();
    final searching = q.isNotEmpty;
    final qDigits = q.replaceAll(RegExp(r'\D'), '');
    final visible = searching
        ? widget.people.where((p) {
            if (p.display.toLowerCase().contains(q)) return true;
            return qDigits.isNotEmpty && p.phone.contains(qDigits);
          }).toList()
        : widget.people
            .where((p) => widget.selected.contains(p.phone))
            .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        TextField(
          controller: _controller,
          decoration: InputDecoration(
            isDense: true,
            prefixIcon: const Icon(Icons.search),
            hintText: 'Search people by name or number',
            border: const OutlineInputBorder(),
            suffixIcon: searching
                ? IconButton(
                    icon: const Icon(Icons.close),
                    tooltip: 'Clear',
                    onPressed: () {
                      _controller.clear();
                      setState(() => _query = '');
                    },
                  )
                : null,
          ),
          onChanged: (v) => setState(() => _query = v),
        ),
        if (!searching)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              visible.isEmpty
                  ? 'Search above to add people.'
                  : '${visible.length} selected — search to add more.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        if (searching && visible.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text('No matches for “${_query.trim()}”.'),
          ),
        for (final person in visible)
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: Text(person.display),
            subtitle:
                person.display == person.phone ? null : Text(person.phone),
            value: widget.selected.contains(person.phone),
            onChanged: (v) => widget.onChanged(person.phone, v == true),
          ),
      ],
    );
  }
}
