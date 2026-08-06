class CastMember {
  final String name;
  final String? character;
  final String? profileUrl;

  const CastMember({
    required this.name,
    this.character,
    this.profileUrl,
  });

  factory CastMember.fromJson(Map<String, dynamic> json) {
    return CastMember(
      name: json['name'] as String,
      character: json['character'] as String?,
      profileUrl: json['profileUrl'] as String?,
    );
  }
}
