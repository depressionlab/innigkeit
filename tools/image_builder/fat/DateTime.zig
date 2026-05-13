const FATDateTime = @This();

const std = @import("std");
const filesystem = @import("filesystem");

date: filesystem.fat.Date,
time: filesystem.fat.Time,

// Units of 10 milliseconds
subsecond: u8,

pub fn create(io: std.Io) FATDateTime {
    const unix_timestamp_ms = std.Io.Timestamp.now(io, .real).toMilliseconds();
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(@divFloor(unix_timestamp_ms, std.time.ms_per_s)) };

    const epoch_days = epoch_seconds.getEpochDay();
    const year_day = epoch_days.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();

    return .{
        .date = .{
            .year = @intCast(year_day.year - 1980), // -10 to account for unix epoch vs dos epoch
            .month = @intCast(@intFromEnum(month_day.month)),
            .day = @intCast(month_day.day_index),
        },

        .time = .{
            .hour = @intCast(day_seconds.getHoursIntoDay()),
            .minute = @intCast(day_seconds.getMinutesIntoHour()),
            .second_2s = @intCast(day_seconds.getSecondsIntoMinute() / 2),
        },

        .subsecond = @intCast(
            @divFloor(
                @mod(unix_timestamp_ms, std.time.ms_per_s),
                10,
            ),
        ),
    };
}
