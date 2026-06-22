export interface GpsMeasurement {
  longitude: number;
  latitude: number;
  accuracy: number;
  speed: number;
  timestamp: number;
}

export interface GpsFilterResult {
  longitude: number;
  latitude: number;
  speed: number;
  accepted: boolean;
  predicted: boolean;
  reason: string;
  innovationMeter: number;
}

interface AxisState {
  position: number;
  velocity: number;
  p00: number;
  p01: number;
  p10: number;
  p11: number;
}

export class GpsKalmanFilter {
  private initialized: boolean = false;
  private originLongitude: number = 0;
  private originLatitude: number = 0;
  private east: AxisState = this.createAxis();
  private north: AxisState = this.createAxis();
  private lastTimestamp: number = 0;
  private lastAcceptedTimestamp: number = 0;
  private stationaryCandidateCount: number = 0;
  private readonly maxAccuracyMeter: number = 20;
  private readonly maxPredictionSeconds: number = 3;
  private readonly accelerationNoise: number = 4;

  public reset(): void {
    this.initialized = false;
    this.originLongitude = 0;
    this.originLatitude = 0;
    this.east = this.createAxis();
    this.north = this.createAxis();
    this.lastTimestamp = 0;
    this.lastAcceptedTimestamp = 0;
    this.stationaryCandidateCount = 0;
  }

  public update(measurement: GpsMeasurement): GpsFilterResult {
    if (!this.isCoordinateValid(measurement.longitude, measurement.latitude)) {
      return this.currentResult(false, false, 'invalid_coordinate', 0);
    }

    if (!this.initialized) {
      if (measurement.accuracy <= 0 || measurement.accuracy > this.maxAccuracyMeter) {
        return {
          longitude: measurement.longitude,
          latitude: measurement.latitude,
          speed: 0,
          accepted: false,
          predicted: false,
          reason: 'poor_initial_accuracy',
          innovationMeter: 0
        };
      }
      this.initialize(measurement);
      return this.currentResult(true, false, 'initialized', 0);
    }

    if (measurement.timestamp <= this.lastTimestamp) {
      return this.currentResult(false, false, 'stale_timestamp', 0);
    }

    const dt: number = Math.min(Math.max((measurement.timestamp - this.lastTimestamp) / 1000, 0.05), 5);
    this.predictAxis(this.east, dt);
    this.predictAxis(this.north, dt);
    this.lastTimestamp = measurement.timestamp;

    const local: number[] = this.toLocalMeters(measurement.longitude, measurement.latitude);
    const innovationEast: number = local[0] - this.east.position;
    const innovationNorth: number = local[1] - this.north.position;
    const innovationMeter: number = Math.sqrt(
      innovationEast * innovationEast + innovationNorth * innovationNorth
    );
    const safeAccuracy: number = Math.max(measurement.accuracy, 3);
    const expectedTravel: number = Math.max(measurement.speed, 0) * dt;
    const allowedInnovation: number = Math.max(safeAccuracy * 3, expectedTravel + 15);

    if (measurement.accuracy <= 0 || measurement.accuracy > this.maxAccuracyMeter) {
      return this.predictionOrHold(measurement.timestamp, 'poor_accuracy', innovationMeter);
    }
    if (innovationMeter > allowedInnovation) {
      return this.predictionOrHold(measurement.timestamp, 'impossible_jump', innovationMeter);
    }

    const measurementNoise: number = safeAccuracy * safeAccuracy;
    this.updateAxis(this.east, local[0], measurementNoise);
    this.updateAxis(this.north, local[1], measurementNoise);
    const stationaryRadius: number = Math.max(safeAccuracy, 5);
    if (measurement.speed < 0.5 && innovationMeter <= stationaryRadius) {
      this.stationaryCandidateCount += 1;
      this.east.velocity *= 0.25;
      this.north.velocity *= 0.25;
      if (this.stationaryCandidateCount >= 3) {
        this.east.velocity = 0;
        this.north.velocity = 0;
      }
    } else {
      this.stationaryCandidateCount = 0;
    }
    this.lastAcceptedTimestamp = measurement.timestamp;
    return this.currentResult(true, false, 'accepted', innovationMeter);
  }

  private initialize(measurement: GpsMeasurement): void {
    this.initialized = true;
    this.originLongitude = measurement.longitude;
    this.originLatitude = measurement.latitude;
    this.east = this.createAxis();
    this.north = this.createAxis();
    const initialVariance: number = Math.max(measurement.accuracy, 3) ** 2;
    this.east.p00 = initialVariance;
    this.north.p00 = initialVariance;
    this.lastTimestamp = measurement.timestamp;
    this.lastAcceptedTimestamp = measurement.timestamp;
  }

  private createAxis(): AxisState {
    return {
      position: 0,
      velocity: 0,
      p00: 100,
      p01: 0,
      p10: 0,
      p11: 100
    };
  }

  private predictAxis(axis: AxisState, dt: number): void {
    axis.position += axis.velocity * dt;
    const oldP00: number = axis.p00;
    const oldP01: number = axis.p01;
    const oldP10: number = axis.p10;
    const oldP11: number = axis.p11;
    const q: number = this.accelerationNoise * this.accelerationNoise;
    const dt2: number = dt * dt;
    const dt3: number = dt2 * dt;
    const dt4: number = dt2 * dt2;
    axis.p00 = oldP00 + dt * (oldP10 + oldP01) + dt2 * oldP11 + q * dt4 / 4;
    axis.p01 = oldP01 + dt * oldP11 + q * dt3 / 2;
    axis.p10 = oldP10 + dt * oldP11 + q * dt3 / 2;
    axis.p11 = oldP11 + q * dt2;
  }

  private updateAxis(axis: AxisState, measurement: number, measurementNoise: number): void {
    const innovation: number = measurement - axis.position;
    const innovationVariance: number = axis.p00 + measurementNoise;
    const k0: number = axis.p00 / innovationVariance;
    const k1: number = axis.p10 / innovationVariance;
    const oldP00: number = axis.p00;
    const oldP01: number = axis.p01;
    axis.position += k0 * innovation;
    axis.velocity += k1 * innovation;
    axis.p00 = (1 - k0) * oldP00;
    axis.p01 = (1 - k0) * oldP01;
    axis.p10 = axis.p10 - k1 * oldP00;
    axis.p11 = axis.p11 - k1 * oldP01;
  }

  private predictionOrHold(timestamp: number, reason: string, innovationMeter: number): GpsFilterResult {
    const predictionAge: number = (timestamp - this.lastAcceptedTimestamp) / 1000;
    if (predictionAge > this.maxPredictionSeconds) {
      this.east.velocity = 0;
      this.north.velocity = 0;
    }
    return this.currentResult(
      false,
      predictionAge <= this.maxPredictionSeconds,
      predictionAge <= this.maxPredictionSeconds ? `${reason}_predicted` : `${reason}_held`,
      innovationMeter
    );
  }

  private currentResult(
    accepted: boolean,
    predicted: boolean,
    reason: string,
    innovationMeter: number
  ): GpsFilterResult {
    if (!this.initialized) {
      return {
        longitude: 0,
        latitude: 0,
        speed: 0,
        accepted: accepted,
        predicted: predicted,
        reason: reason,
        innovationMeter: innovationMeter
      };
    }
    const coordinate: number[] = this.toCoordinate(this.east.position, this.north.position);
    const filteredSpeed: number = Math.sqrt(
      this.east.velocity * this.east.velocity + this.north.velocity * this.north.velocity
    );
    return {
      longitude: coordinate[0],
      latitude: coordinate[1],
      speed: filteredSpeed < 0.15 ? 0 : filteredSpeed,
      accepted: accepted,
      predicted: predicted,
      reason: reason,
      innovationMeter: innovationMeter
    };
  }

  private toLocalMeters(longitude: number, latitude: number): number[] {
    const earthRadius: number = 6371000;
    const radians: number = Math.PI / 180;
    const east: number = (longitude - this.originLongitude) * radians * earthRadius *
      Math.cos(this.originLatitude * radians);
    const north: number = (latitude - this.originLatitude) * radians * earthRadius;
    return [east, north];
  }

  private toCoordinate(east: number, north: number): number[] {
    const earthRadius: number = 6371000;
    const degrees: number = 180 / Math.PI;
    const latitude: number = this.originLatitude + north / earthRadius * degrees;
    const longitude: number = this.originLongitude + east /
      (earthRadius * Math.cos(this.originLatitude * Math.PI / 180)) * degrees;
    return [longitude, latitude];
  }

  private isCoordinateValid(longitude: number, latitude: number): boolean {
    return longitude >= -180 && longitude <= 180 && latitude >= -90 && latitude <= 90 &&
      longitude !== 0 && latitude !== 0;
  }
}
