package controllers

import (
	"context"
	"errors"
	"testing"

	"github.com/golang/mock/gomock"
	"github.com/milvus-io/milvus-operator/apis/milvus.io/v1alpha1"
	"github.com/stretchr/testify/assert"
	"sigs.k8s.io/controller-runtime/pkg/client"
	logf "sigs.k8s.io/controller-runtime/pkg/log"
)

func TestStatusSyncer_syncUnhealthy(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockCli := NewMockK8sClient(ctrl)
	ctx := context.Background()
	logger := logf.Log.WithName("test")
	s := NewMilvusStatusSyncer(ctx, mockCli, logger)

	mockRunner := NewMockGroupRunner(ctrl)
	defaultGroupRunner = mockRunner

	// list failed err
	mockCli.EXPECT().List(gomock.Any(), gomock.Any()).Return(errors.New("test"))
	err := s.syncUnhealthy()
	assert.Error(t, err)

	// status not set, healthy, not run
	mockCli.EXPECT().List(gomock.Any(), gomock.Any()).
		Do(func(ctx context.Context, list *v1alpha1.MilvusList, opts ...client.ListOption) {
			list.Items = []v1alpha1.Milvus{
				{},
				{},
			}
			list.Items[1].Status.Status = v1alpha1.StatusHealthy
		})
	mockRunner.EXPECT().RunDiffArgs(gomock.Any(), gomock.Any(), gomock.Len(0))
	s.syncUnhealthy()

	// status unhealthy, run
	mockCli.EXPECT().List(gomock.Any(), gomock.Any()).
		Do(func(ctx context.Context, list *v1alpha1.MilvusList, opts ...client.ListOption) {
			list.Items = []v1alpha1.Milvus{
				{},
				{},
				{},
			}
			list.Items[1].Status.Status = v1alpha1.StatusUnHealthy
			list.Items[2].Status.Status = v1alpha1.StatusUnHealthy
		})
	mockRunner.EXPECT().RunDiffArgs(gomock.Any(), gomock.Any(), gomock.Len(2))
	s.syncUnhealthy()
}

func TestStatusSyncer_syncHealthy(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockCli := NewMockK8sClient(ctrl)
	ctx := context.Background()
	logger := logf.Log.WithName("test")
	s := NewMilvusStatusSyncer(ctx, mockCli, logger)

	mockRunner := NewMockGroupRunner(ctrl)
	defaultGroupRunner = mockRunner

	// list failed err
	mockCli.EXPECT().List(gomock.Any(), gomock.Any()).Return(errors.New("test"))
	err := s.syncHealthy()
	assert.Error(t, err)

	// status not set, unhealthy, not run
	mockCli.EXPECT().List(gomock.Any(), gomock.Any()).
		Do(func(ctx context.Context, list *v1alpha1.MilvusList, opts ...client.ListOption) {
			list.Items = []v1alpha1.Milvus{
				{},
				{},
			}
			list.Items[1].Status.Status = v1alpha1.StatusUnHealthy
		})
	mockRunner.EXPECT().RunDiffArgs(gomock.Any(), gomock.Any(), gomock.Len(0))
	s.syncHealthy()

	// status unhealthy, run
	mockCli.EXPECT().List(gomock.Any(), gomock.Any()).
		Do(func(ctx context.Context, list *v1alpha1.MilvusList, opts ...client.ListOption) {
			list.Items = []v1alpha1.Milvus{
				{},
				{},
				{},
			}
			list.Items[1].Status.Status = v1alpha1.StatusHealthy
			list.Items[2].Status.Status = v1alpha1.StatusHealthy
		})
	mockRunner.EXPECT().RunDiffArgs(gomock.Any(), gomock.Any(), gomock.Len(2))
	s.syncHealthy()
}

func TestStatusSyncer_UpdateStatus(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockCli := NewMockK8sClient(ctrl)
	ctx := context.Background()
	logger := logf.Log.WithName("test")
	m := &v1alpha1.Milvus{}
	s := NewMilvusStatusSyncer(ctx, mockCli, logger)

	// default status not set
	err := s.UpdateStatus(ctx, m)
	assert.NoError(t, err)

	// get condition failed
	mockRunner := NewMockGroupRunner(ctrl)
	defaultGroupRunner = mockRunner
	mockRunner.EXPECT().RunWithResult(gomock.Len(2), gomock.Any(), gomock.Any()).
		Return([]Result{
			{Err: errors.New("test")},
			{Err: errors.New("test")},
		})

	m.Status.Status = v1alpha1.StatusCreating
	err = s.UpdateStatus(ctx, m)
	assert.Error(t, err)

	// update status success
	mockRunner.EXPECT().RunWithResult(gomock.Len(2), gomock.Any(), gomock.Any()).
		Return([]Result{
			{Data: v1alpha1.MilvusCondition{}},
		})
	mockCli.EXPECT().Status().Return(mockCli)
	mockCli.EXPECT().Update(gomock.Any(), gomock.Any())
	m.Status.Status = v1alpha1.StatusCreating
	err = s.UpdateStatus(ctx, m)
	assert.NoError(t, err)
}
