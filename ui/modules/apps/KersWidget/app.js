angular.module('beamng.apps')
.directive('kersWidget', [function () {
  return {
    templateUrl: '/ui/modules/apps/KersWidget/app.html',
    replace: true,
    restrict: 'EA',
    link: function (scope, element, attrs) {
      scope.$on('streamsUpdate', function (event, streams) {
        if (!streams || !streams.electrics) return;

        scope.$evalAsync(function () {
          scope.batteryPercent = Math.round(streams.electrics.kersBatteryPercent || 0);
          scope.energykWh = Number(streams.electrics.kersEnergykWh || 0).toFixed(2);
          scope.torquePercent = Math.round(streams.electrics.kersTorquePercent || 0);
          scope.boostActive = streams.electrics.kersBoostActive === 1;
          scope.motorStatus = streams.electrics.kersMotorStatus || 'READY';
        });
      });
    }
  };
}]);