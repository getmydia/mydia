/// Zero-padded `yyyy-MM-dd`, the format the calendar's GraphQL query takes
/// for its `start`/`end` date arguments.
String isoDate(DateTime date) => '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';
