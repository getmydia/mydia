import 'package:flutter/material.dart';
import '../../core/theme/palette.dart';
import '../../domain/detail/detail_views.dart';
import '../../l10n/l10n.dart';
import 'detail_art_image.dart';
import 'horizontal_wheel_scroll.dart';

/// Horizontal rail of cast members below the detail hero. Renders nothing
/// when [members] is empty — there is no empty state, the section just
/// doesn't exist for a title with no persisted cast.
class CastRail extends StatelessWidget {
  final List<CastView> members;

  const CastRail({super.key, required this.members});

  @override
  Widget build(BuildContext context) {
    if (members.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(
            children: [
              Container(
                width: 4,
                height: 20,
                decoration: BoxDecoration(
                  color: context.palette.primary,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 10),
              Text(
                context.l10n.castRailTitle,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        SizedBox(
          height: 128,
          child: HorizontalWheelScroll(
            builder: (context, controller) => ListView.builder(
              controller: controller,
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              itemCount: members.length,
              itemBuilder: (context, index) {
                final member = members[index];
                return Padding(
                  key: ValueKey('cast-${member.name}-$index'),
                  padding: const EdgeInsets.only(right: 14),
                  child: _CastCard(member: member),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

class _CastCard extends StatelessWidget {
  final CastView member;

  const _CastCard({required this.member});

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return SizedBox(
      width: 84,
      child: Column(
        children: [
          ClipOval(
            child: SizedBox(
              width: 72,
              height: 72,
              child: DetailArtImage(
                art: member.photo,
                slot: ArtSlot.person,
                placeholder: (context) =>
                    Container(color: palette.surfaceVariant),
                fallback: (context) => _fallbackAvatar(palette),
                errorWidget: (context) => _fallbackAvatar(palette),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            member.name,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
              color: palette.textPrimary,
            ),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          if (member.character != null)
            Text(
              member.character!,
              style: TextStyle(
                fontSize: 10.5,
                color: palette.textSecondary,
              ),
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
        ],
      ),
    );
  }

  Widget _fallbackAvatar(MydiaPalette palette) {
    return Container(
      color: palette.surfaceVariant,
      child: Icon(Icons.person_rounded, color: palette.textSecondary),
    );
  }
}
